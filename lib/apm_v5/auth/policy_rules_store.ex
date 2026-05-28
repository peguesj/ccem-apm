defmodule ApmV5.Auth.PolicyRulesStore do
  @moduledoc """
  Persists permanent allow/deny overrides for specific tools.

  Rules take priority over PolicyEngine risk evaluation:
  - `:always_allow` — skip all risk checks, immediately grant token
  - `:always_deny`  — immediately deny regardless of role/context

  ETS table `:agentlock_policy_rules` is public so PolicyEngine can
  read it directly without a GenServer call (hot path).
  """

  use GenServer
  require Logger

  @table :agentlock_policy_rules

  # ── Client API ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Add or overwrite a permanent rule for a tool."
  @spec add_rule(String.t(), :always_allow | :always_deny) :: :ok
  def add_rule(tool_name, action) when action in [:always_allow, :always_deny] do
    GenServer.call(__MODULE__, {:add_rule, tool_name, action})
  end

  @doc "Remove a permanent rule for a tool (reverts to normal policy)."
  @spec remove_rule(String.t()) :: :ok
  def remove_rule(tool_name) do
    GenServer.call(__MODULE__, {:remove_rule, tool_name})
  end

  @doc "List all active rules as JSON-safe maps."
  @spec list_rules() :: [map()]
  def list_rules do
    case :ets.info(@table) do
      :undefined -> []
      _ ->
        :ets.tab2list(@table)
        |> Enum.map(fn {name, action, inserted_at} ->
          %{tool_name: name, action: action, inserted_at: DateTime.to_iso8601(inserted_at)}
        end)
        |> Enum.sort_by(& &1.tool_name)
    end
  end

  @doc """
  Serialize all current PolicyRulesStore rules + AutoApprovalStore policies as a
  Rego policy bundle (text/plain).

  The output is a valid OPA Rego policy that mirrors the in-memory ETS state.
  Callers can POST this bundle to an OPA sidecar to bootstrap its policy set.

  ## Example

      iex> ApmV5.Auth.PolicyRulesStore.add_rule("Bash", :always_deny)
      :ok
      iex> rego = ApmV5.Auth.PolicyRulesStore.to_rego()
      iex> String.contains?(rego, "package apm.agentlock")
      true
      iex> String.contains?(rego, "always_deny")
      true

  """
  @spec to_rego() :: String.t()
  def to_rego do
    rules = list_rules()

    auto_approval_lines =
      case Process.whereis(ApmV5.Auth.AutoApprovalStore) do
        nil -> []
        _pid -> ApmV5.Auth.AutoApprovalStore.list_active()
      end

    rules_block =
      Enum.map(rules, fn r ->
        action_str = to_string(r.action)
        "  #{action_str}[\"#{r.tool_name}\"] = true"
      end)
      |> Enum.join("\n")

    auto_block =
      Enum.map(auto_approval_lines, fn p ->
        tools =
          case p.allowed_tools do
            :all -> "\"*\""
            list -> "[#{Enum.map_join(list, ", ", &"\"#{&1}\"")}]"
          end

        "  # policy_id=#{p.policy_id} agent=#{inspect(p.agent_id)} tools=#{tools}\n" <>
          "  auto_approved_policies[\"#{p.policy_id}\"] = true"
      end)
      |> Enum.join("\n")

    generated_at = DateTime.utc_now() |> DateTime.to_iso8601()

    """
    # CCEM APM AgentLock — generated Rego policy
    # Generated: #{generated_at}
    # Source: ApmV5.Auth.PolicyRulesStore.to_rego/0
    # DO NOT EDIT — regenerate from /api/v2/auth/policy/rego

    package apm.agentlock

    import future.keywords.if
    import future.keywords.in

    # ── Permanent allow/deny rules ─────────────────────────────────────────────
    #{if rules_block == "", do: "  # (no permanent rules defined)", else: rules_block}

    # ── Auto-approval policies ─────────────────────────────────────────────────
    #{if auto_block == "", do: "  # (no active auto-approval policies)", else: auto_block}

    # ── Decision entrypoints ───────────────────────────────────────────────────

    default allow = false

    allow if {
      always_allow[input.tool_name]
    }

    deny if {
      always_deny[input.tool_name]
    }

    allow if {
      not deny
      auto_approved_policies[_]
    }
    """
    |> String.trim_trailing()
  end

  @doc "Check if a tool has a permanent rule. Returns :always_allow | :always_deny | :none.
  Supports \"*\" wildcard stored under the literal key \"*\" — matches any tool when no exact rule exists."
  @spec check_rule(String.t()) :: :always_allow | :always_deny | :none
  def check_rule(tool_name) do
    case :ets.info(@table) do
      :undefined -> :none
      _ ->
        case :ets.lookup(@table, tool_name) do
          [{^tool_name, action, _}] -> action
          [] ->
            case :ets.lookup(@table, "*") do
              [{"*", action, _}] -> action
              [] -> :none
            end
        end
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:add_rule, tool_name, action}, _from, state) do
    :ets.insert(@table, {tool_name, action, DateTime.utc_now()})
    Logger.info("[PolicyRulesStore] Rule set: #{tool_name} → #{action}")

    # KRI: policy_rule_changes (create or update)
    :telemetry.execute(
      [:apm_v5, :governance, :policy_rule_changes],
      %{count: 1},
      %{tool_name: tool_name, action: action, change_type: :upsert}
    )

    Phoenix.PubSub.broadcast(ApmV5.PubSub, "agentlock:authorization", {:policy_rule_added, %{
      tool_name: tool_name,
      action: action,
      inserted_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:remove_rule, tool_name}, _from, state) do
    :ets.delete(@table, tool_name)
    Logger.info("[PolicyRulesStore] Rule removed: #{tool_name}")

    # KRI: policy_rule_changes (delete)
    :telemetry.execute(
      [:apm_v5, :governance, :policy_rule_changes],
      %{count: 1},
      %{tool_name: tool_name, action: :none, change_type: :delete}
    )

    Phoenix.PubSub.broadcast(ApmV5.PubSub, "agentlock:authorization", {:policy_rule_removed, %{
      tool_name: tool_name
    }})

    {:reply, :ok, state}
  end
end
