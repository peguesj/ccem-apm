defmodule Apm.Auth.PolicyRulesStore do
  @moduledoc """
  Persists permanent allow/deny overrides for specific tools.

  Rules take priority over PolicyEngine risk evaluation:
  - `:always_allow` — skip all risk checks, immediately grant token
  - `:always_deny`  — immediately deny regardless of role/context

  ## v9.4.0 — Versioning + Attestation (CP-285)

  Each rule now carries a monotonic `version` counter, `created_by` (required),
  `approved_by` (optional), and `expires_at` (optional `DateTime`).

  - `version` increments on every `add_rule/3` call for the same tool.
  - Rules with a past `expires_at` are auto-demoted to `:none` by `check_rule/1`.
  - `policy_history/1` returns the full ordered changelog for a given tool.

  ## ETS layout

  Primary table `:agentlock_policy_rules` (public, `read_concurrency: true`):
  ```
  {tool_name, action, version, created_by, approved_by, expires_at, inserted_at}
  ```

  History table `:agentlock_policy_rules_history` (protected):
  ```
  {{tool_name, version}, action, created_by, approved_by, expires_at, inserted_at}
  ```
  """

  use GenServer
  require Logger

  @table :agentlock_policy_rules
  @history_table :agentlock_policy_rules_history

  # ── Client API ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Add or overwrite a permanent rule for a tool.

  ## Options
  - `:created_by` — string identity of the operator adding the rule (default `"system"`)
  - `:approved_by` — string identity of the approver (default `nil`)
  - `:expires_at`  — `DateTime` after which the rule auto-demotes to `:none` (default `nil`)
  """
  @spec add_rule(String.t(), :always_allow | :always_deny, keyword()) :: :ok
  def add_rule(tool_name, action, opts \\ []) when action in [:always_allow, :always_deny] do
    GenServer.call(__MODULE__, {:add_rule, tool_name, action, opts})
  end

  @doc "Remove a permanent rule for a tool (reverts to normal policy)."
  @spec remove_rule(String.t()) :: :ok
  def remove_rule(tool_name) do
    GenServer.call(__MODULE__, {:remove_rule, tool_name})
  end

  @doc "List all active rules as JSON-safe maps (excludes expired entries)."
  @spec list_rules() :: [map()]
  def list_rules do
    case :ets.info(@table) do
      :undefined ->
        []

      _ ->
        now = DateTime.utc_now()

        :ets.tab2list(@table)
        |> Enum.reject(fn {_name, _action, _version, _created_by, _approved_by, expires_at,
                           _inserted_at} ->
          expired?(expires_at, now)
        end)
        |> Enum.map(fn {name, action, version, created_by, approved_by, expires_at, inserted_at} ->
          %{
            tool_name: name,
            action: action,
            version: version,
            created_by: created_by,
            approved_by: approved_by,
            expires_at: if(expires_at, do: DateTime.to_iso8601(expires_at)),
            inserted_at: DateTime.to_iso8601(inserted_at)
          }
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

      iex> Apm.Auth.PolicyRulesStore.add_rule("Bash", :always_deny)
      :ok
      iex> rego = Apm.Auth.PolicyRulesStore.to_rego()
      iex> String.contains?(rego, "package apm.agentlock")
      true
      iex> String.contains?(rego, "always_deny")
      true

  """
  @spec to_rego() :: String.t()
  def to_rego do
    rules = list_rules()

    auto_approval_lines =
      case Process.whereis(Apm.Auth.AutoApprovalStore) do
        nil -> []
        _pid -> Apm.Auth.AutoApprovalStore.list_active()
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
    # Source: Apm.Auth.PolicyRulesStore.to_rego/0
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

  @doc """
  Check if a tool has a permanent rule.

  Returns `:always_allow | :always_deny | :none`.

  Supports `"*"` wildcard stored under the literal key `"*"` — matches any tool
  when no exact rule exists. Rules with a past `expires_at` are auto-demoted
  to `:none` without modifying ETS (lazy expiry).
  """
  @spec check_rule(String.t()) :: :always_allow | :always_deny | :none
  def check_rule(tool_name) do
    case :ets.info(@table) do
      :undefined ->
        :none

      _ ->
        now = DateTime.utc_now()

        case :ets.lookup(@table, tool_name) do
          [{^tool_name, action, _version, _created_by, _approved_by, expires_at, _inserted_at}] ->
            if expired?(expires_at, now), do: :none, else: action

          [] ->
            case :ets.lookup(@table, "*") do
              [{"*", action, _version, _created_by, _approved_by, expires_at, _inserted_at}] ->
                if expired?(expires_at, now), do: :none, else: action

              [] ->
                :none
            end
        end
    end
  end

  @doc """
  Return the full entry for a tool, or `nil` if not found.

  The returned map includes: `tool_name`, `action`, `version`, `created_by`,
  `approved_by`, `expires_at`, `inserted_at`.
  """
  @spec get_rule_entry(String.t()) :: map() | nil
  def get_rule_entry(tool_name) do
    case :ets.info(@table) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(@table, tool_name) do
          [{^tool_name, action, version, created_by, approved_by, expires_at, inserted_at}] ->
            %{
              tool_name: tool_name,
              action: action,
              version: version,
              created_by: created_by,
              approved_by: approved_by,
              expires_at: expires_at,
              inserted_at: inserted_at
            }

          [] ->
            nil
        end
    end
  end

  @doc """
  Delete all history entries for a tool. Intended for test teardown only.
  Routes through the GenServer so the protected ETS table can be modified.
  """
  @spec clear_tool_history(String.t()) :: :ok
  def clear_tool_history(tool_name) do
    GenServer.call(__MODULE__, {:clear_tool_history, tool_name})
  end

  @doc """
  Return the versioned changelog for a specific tool, ordered ascending by version.

  Each entry is a map with: `version`, `action`, `created_by`, `approved_by`,
  `expires_at`, `inserted_at` (ISO 8601 string).
  Returns `[]` if no history exists.
  """
  @spec policy_history(String.t()) :: [map()]
  def policy_history(tool_name) do
    case :ets.info(@history_table) do
      :undefined ->
        []

      _ ->
        # Collect all history entries whose key matches {tool_name, _version}
        :ets.match_object(@history_table, {{tool_name, :_}, :_, :_, :_, :_, :_})
        |> Enum.map(fn {{_name, version}, action, created_by, approved_by, expires_at,
                        inserted_at} ->
          %{
            version: version,
            action: action,
            created_by: created_by,
            approved_by: approved_by,
            expires_at: if(expires_at, do: DateTime.to_iso8601(expires_at)),
            inserted_at: DateTime.to_iso8601(inserted_at)
          }
        end)
        |> Enum.sort_by(& &1.version)
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@history_table, [:named_table, :bag, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:add_rule, tool_name, action, opts}, _from, state) do
    created_by = Keyword.get(opts, :created_by, "system")
    approved_by = Keyword.get(opts, :approved_by, nil)
    expires_at = Keyword.get(opts, :expires_at, nil)
    now = DateTime.utc_now()

    # Determine next version (monotonic per tool)
    version =
      case :ets.lookup(@table, tool_name) do
        [{^tool_name, _action, prev_version, _cb, _ab, _exp, _ins}] -> prev_version + 1
        [] -> 1
      end

    :ets.insert(@table, {tool_name, action, version, created_by, approved_by, expires_at, now})

    # Append to history
    :ets.insert(
      @history_table,
      {{tool_name, version}, action, created_by, approved_by, expires_at, now}
    )

    Logger.info(
      "[PolicyRulesStore] Rule set: #{tool_name} → #{action} (v#{version}, by: #{created_by})"
    )

    # KRI: policy_rule_changes (create or update)
    :telemetry.execute(
      [:apm, :governance, :policy_rule_changes],
      %{count: 1},
      %{tool_name: tool_name, action: action, change_type: :upsert, version: version}
    )

    Phoenix.PubSub.broadcast(
      Apm.PubSub,
      "agentlock:authorization",
      {:policy_rule_added,
       %{
         tool_name: tool_name,
         action: action,
         version: version,
         created_by: created_by,
         inserted_at: DateTime.to_iso8601(now)
       }}
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:clear_tool_history, tool_name}, _from, state) do
    case :ets.info(@history_table) do
      :undefined -> :ok
      _ -> :ets.match_delete(@history_table, {{tool_name, :_}, :_, :_, :_, :_, :_})
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:remove_rule, tool_name}, _from, state) do
    :ets.delete(@table, tool_name)
    Logger.info("[PolicyRulesStore] Rule removed: #{tool_name}")

    # KRI: policy_rule_changes (delete)
    :telemetry.execute(
      [:apm, :governance, :policy_rule_changes],
      %{count: 1},
      %{tool_name: tool_name, action: :none, change_type: :delete}
    )

    Phoenix.PubSub.broadcast(
      Apm.PubSub,
      "agentlock:authorization",
      {:policy_rule_removed,
       %{
         tool_name: tool_name
       }}
    )

    {:reply, :ok, state}
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp expired?(nil, _now), do: false
  defp expired?(expires_at, now), do: DateTime.compare(expires_at, now) == :lt
end
