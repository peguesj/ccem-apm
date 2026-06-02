defmodule Apm.Auth.AutoApprovalStore do
  @moduledoc """
  Manages auto-approval policies for hierarchical scope matching.

  Auto-approval policies enable automatic approval of tool calls matching specific criteria:
  - agent_id (or nil for any)
  - formation_id (or nil for any)
  - session_id (or nil for any)
  - project (or nil for any)
  - allowed_tools (list or :all)
  - allowed_risk_levels (list or :all)
  - time window (active_from .. expires_at)

  Matching is AND logic: all specified scopes must match.
  Precedence: Most specific scope wins (agent > formation > session > project).

  ETS table `:auto_approval_policies` stores:
    `{policy_id, policy_map}`

  ## Example Usage

      # Create a policy to auto-approve all low-risk tools for a specific agent
      {:ok, policy_id} = Apm.Auth.AutoApprovalStore.create(%{
        agent_id: "ag-123",
        allowed_tools: :all,
        allowed_risk_levels: [:none, :low],
        reason: "development session"
      })

      # Find matching policy for a tool call
      case Apm.Auth.AutoApprovalStore.find_matching(agent_id, formation_id, session_id, project, tool_name, risk_level) do
        nil -> :no_matching_policy
        policy -> {:auto_approved, policy.policy_id}
      end
  """

  use GenServer
  require Logger

  @table :auto_approval_policies
  @ttl_seconds 3600  # Policies expire after 1 hour by default
  @sweep_ms 30_000   # Check for expired policies every 30 seconds

  # ── Client API ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Create a new auto-approval policy.

  Returns `{:ok, policy_id}` on success.

  ## Parameters

  - `agent_id` — (optional) agent UUID; nil = match any agent
  - `formation_id` — (optional) formation UUID; nil = match any formation
  - `formation_role` — (optional) formation role atom (:orchestrator, :swarm_agent, etc); nil = any
  - `session_id` — (optional) session UUID; nil = match any session
  - `project` — (optional) project name; nil = match any project
  - `allowed_tools` — :all or list of tool names (e.g., ["Read", "Edit"])
  - `allowed_risk_levels` — :all or list of risk levels (e.g., [:low, :medium])
  - `allowed_action_types` — (optional) :all or list of action types (e.g., [:read, :write]); :all = any action type
  - `action_patterns` — (optional) list of glob patterns for command matching (e.g., ["cat /app/**", "grep /var/**"])
  - `active_from` — (optional) DateTime; defaults to now
  - `expires_at` — (optional) DateTime; defaults to now + 1 hour
  - `created_by` — (optional) string (e.g., "user", "hook", "admin"); defaults to "system"
  - `reason` — (optional) string explaining the policy
  """
  @spec create(map()) :: {:ok, String.t()} | {:error, term()}
  def create(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:create, attrs})
  end

  @doc """
  List all currently active auto-approval policies.

  Returns list of policy maps sorted by updated_at (newest first).
  """
  @spec list_active() :: [map()]
  def list_active do
    now = DateTime.utc_now()
    case :ets.info(@table) do
      :undefined -> []
      _ ->
        :ets.tab2list(@table)
        |> Enum.map(fn {_id, policy} -> policy end)
        |> Enum.filter(&(DateTime.after?(&1.expires_at, now) and DateTime.before?(&1.active_from, now)))
        |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
    end
  end

  @doc """
  Find a matching auto-approval policy for a tool call.

  Returns the most specific matching policy or nil if none match.

  ## Matching Rules
  - All specified scopes must match (AND logic)
  - Policy precedence: agent_id > formation_id > session_id > project
  - Within same specificity level: most recent policy (updated_at) wins
  - Optional: action_type can be used to restrict by command category (:read, :write, :destructive)
  """
  @spec find_matching(
    String.t() | nil,
    String.t() | nil,
    String.t() | nil,
    String.t() | nil,
    String.t(),
    atom(),
    atom() | nil
  ) :: map() | nil
  def find_matching(agent_id, formation_id, session_id, project, tool_name, risk_level, action_type \\ nil) do
    list_active()
    |> Enum.filter(fn p ->
      matches_scope?(p, agent_id, formation_id, session_id, project) &&
        matches_tool?(p, tool_name, risk_level) &&
        matches_action_type?(p, action_type)
    end)
    |> Enum.sort_by(&specificity_score/1, :desc)
    |> List.first()
  end

  @doc "Get a specific policy by ID."
  @spec get(String.t()) :: map() | nil
  def get(policy_id) do
    case :ets.lookup(@table, policy_id) do
      [{^policy_id, policy}] -> policy
      [] -> nil
    end
  end

  @doc """
  Update an existing policy.

  Returns `{:ok, updated_policy}` or `{:error, :not_found}`.
  """
  @spec update(String.t(), map()) :: {:ok, map()} | {:error, :not_found}
  def update(policy_id, updates) do
    GenServer.call(__MODULE__, {:update, policy_id, updates})
  end

  @doc """
  Delete a policy by ID.

  Returns `:ok` or `{:error, :not_found}`.
  """
  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(policy_id) do
    GenServer.call(__MODULE__, {:delete, policy_id})
  end

  @doc """
  Increment the approval counter for a policy.

  Called when a policy is matched and auto-approval occurs.
  Returns `:ok` or `{:error, :not_found}`.
  """
  @spec increment_approval_count(String.t()) :: :ok | {:error, :not_found}
  def increment_approval_count(policy_id) do
    GenServer.call(__MODULE__, {:increment_approval_count, policy_id})
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create, attrs}, _from, state) do
    policy_id = "ap-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
    now = DateTime.utc_now()

    policy = %{
      policy_id: policy_id,
      agent_id: Map.get(attrs, :agent_id),
      formation_id: Map.get(attrs, :formation_id),
      formation_role: Map.get(attrs, :formation_role),
      session_id: Map.get(attrs, :session_id),
      project: Map.get(attrs, :project),
      allowed_tools: Map.get(attrs, :allowed_tools, :all),
      allowed_risk_levels: Map.get(attrs, :allowed_risk_levels, :all),
      allowed_action_types: Map.get(attrs, :allowed_action_types, :all),
      action_patterns: Map.get(attrs, :action_patterns, []),
      active_from: Map.get(attrs, :active_from, now),
      expires_at: Map.get(attrs, :expires_at, DateTime.add(now, @ttl_seconds, :second)),
      created_by: Map.get(attrs, :created_by, "system"),
      reason: Map.get(attrs, :reason, ""),
      approval_count: 0,
      inserted_at: now,
      updated_at: now
    }

    :ets.insert(@table, {policy_id, policy})

    Phoenix.PubSub.broadcast(
      Apm.PubSub,
      "agentlock:auto-approval-policy",
      {:policy_created, policy}
    )

    Logger.info("[AutoApprovalStore] Created policy #{policy_id} — #{policy.reason}")
    {:reply, {:ok, policy_id}, state}
  end

  @impl true
  def handle_call({:update, policy_id, updates}, _from, state) do
    case :ets.lookup(@table, policy_id) do
      [{^policy_id, policy}] ->
        updated = Map.merge(policy, Map.put(updates, :updated_at, DateTime.utc_now()))
        :ets.insert(@table, {policy_id, updated})

        Phoenix.PubSub.broadcast(
          Apm.PubSub,
          "agentlock:auto-approval-policy",
          {:policy_updated, updated}
        )

        Logger.debug("[AutoApprovalStore] Updated policy #{policy_id}")
        {:reply, {:ok, updated}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:delete, policy_id}, _from, state) do
    case :ets.lookup(@table, policy_id) do
      [{^policy_id, policy}] ->
        :ets.delete(@table, policy_id)

        Phoenix.PubSub.broadcast(
          Apm.PubSub,
          "agentlock:auto-approval-policy",
          {:policy_deleted, policy}
        )

        Logger.info("[AutoApprovalStore] Deleted policy #{policy_id}")
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:increment_approval_count, policy_id}, _from, state) do
    case :ets.lookup(@table, policy_id) do
      [{^policy_id, policy}] ->
        updated = %{policy | approval_count: policy.approval_count + 1}
        :ets.insert(@table, {policy_id, updated})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = DateTime.utc_now()

    expired =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_id, policy} -> DateTime.before?(policy.expires_at, now) end)

    Enum.each(expired, fn {id, _} ->
      :ets.delete(@table, id)
      Logger.debug("[AutoApprovalStore] Expired policy #{id}")
    end)

    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  # ── Private Helpers ──────────────────────────────────────────────────────────

  defp matches_scope?(policy, agent_id, formation_id, session_id, project) do
    (is_nil(policy.agent_id) or policy.agent_id == agent_id) &&
      (is_nil(policy.formation_id) or policy.formation_id == formation_id) &&
      (is_nil(policy.session_id) or policy.session_id == session_id) &&
      (is_nil(policy.project) or policy.project == project)
  end

  defp matches_tool?(policy, tool_name, risk_level) do
    tools_match? = policy.allowed_tools == :all or tool_name in policy.allowed_tools
    risk_match? = policy.allowed_risk_levels == :all or risk_level in policy.allowed_risk_levels

    tools_match? and risk_match?
  end

  defp matches_action_type?(policy, action_type) do
    allowed = Map.get(policy, :allowed_action_types, :all)
    allowed == :all or is_nil(action_type) or action_type in allowed
  end

  defp specificity_score(policy) do
    score =
      (if policy.agent_id, do: 4, else: 0) +
        (if policy.formation_id, do: 3, else: 0) +
        (if policy.session_id, do: 2, else: 0) +
        (if policy.project, do: 1, else: 0)

    {score, policy.updated_at}
  end
end
