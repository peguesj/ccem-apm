defmodule ApmV5.Auth.PolicyEngine do
  @moduledoc """
  Stateless risk evaluation engine for AgentLock authorization.

  Evaluates tool calls against configured policies and returns a
  `PolicyDecision` struct. No GenServer — pure functions called
  by `AuthorizationGate`.

  ## Risk Level Defaults
  - Read, Grep, Glob, LS → :none (auto-permit)
  - Agent, WebFetch, WebSearch → :low
  - Edit, Write, NotebookEdit → :medium
  - Bash → :high (destructive commands → :critical)
  - Skill → :medium
  """

  alias ApmV5.Auth.Types
  alias ApmV5.Auth.Types.{AuthTool, PolicyDecision}

  # Default risk mapping for Claude Code tools
  @default_risk_map %{
    "Read" => :none,
    "Grep" => :none,
    "Glob" => :none,
    "LS" => :none,
    "TaskGet" => :none,
    "TaskList" => :none,
    "TaskCreate" => :low,
    "TaskUpdate" => :low,
    "Agent" => :low,
    "WebFetch" => :low,
    "WebSearch" => :low,
    "Edit" => :medium,
    "Write" => :medium,
    "NotebookEdit" => :medium,
    "Skill" => :medium,
    "Bash" => :high
  }

  @destructive_patterns [
    ~r/rm\s+-rf/,
    ~r/git\s+push\s+--force/,
    ~r/git\s+reset\s+--hard/,
    ~r/drop\s+table/i,
    ~r/drop\s+database/i,
    ~r/pkill\s+-9/,
    ~r/kill\s+-9/,
    ~r/>\s*\/dev\/null/
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Evaluate a tool call against authorization policy.

  Returns a `PolicyDecision` with the risk assessment and allow/deny decision.

  ## Parameters
  - `tool_name` — the tool being invoked (e.g., "Bash", "Write")
  - `role` — the agent's role (e.g., "agent", "admin", "orchestrator")
  - `context` — map with optional keys: `:params`, `:data_boundary`, `:record_count`,
    `:is_bulk`, `:is_external`, `:trust_ceiling`, `:tool_registry` (custom %AuthTool{})
  """
  @spec evaluate(String.t(), String.t(), map()) :: PolicyDecision.t()
  def evaluate(tool_name, role, context \\ %{}) do
    tool = Map.get(context, :tool_registry) || default_tool(tool_name)
    risk = determine_risk(tool_name, tool, context)

    risk
    |> check_auto_permit()
    |> check_role(role, tool)
    |> check_data_boundary(context, tool)
    |> check_bulk_operation(context, tool)
    |> check_trust_ceiling(context)
    |> finalize(risk, tool_name)
  end

  @doc "Returns the default risk level for a tool name."
  @spec default_risk(String.t()) :: Types.risk_level()
  def default_risk(tool_name), do: Map.get(@default_risk_map, tool_name, :low)

  @doc "Returns the full default risk map."
  @spec default_risk_map() :: map()
  def default_risk_map, do: @default_risk_map

  @doc "Checks if a Bash command contains destructive patterns."
  @spec destructive_command?(String.t()) :: boolean()
  def destructive_command?(command) do
    Enum.any?(@destructive_patterns, &Regex.match?(&1, command))
  end

  # ---------------------------------------------------------------------------
  # Pipeline Steps
  # ---------------------------------------------------------------------------

  defp default_tool(tool_name) do
    %AuthTool{
      name: tool_name,
      risk_level: default_risk(tool_name),
      requires_auth: default_risk(tool_name) not in [:none],
      allowed_roles: [],
      registered_at: DateTime.utc_now()
    }
  end

  defp determine_risk(tool_name, tool, context) do
    base_risk = tool.risk_level

    # Escalate Bash to :critical if destructive command detected
    case tool_name do
      "Bash" ->
        command = get_in(context, [:params, "command"]) || ""
        if destructive_command?(command), do: :critical, else: base_risk

      _ ->
        base_risk
    end
  end

  defp check_auto_permit(risk) when risk in [:none] do
    {:permit, %PolicyDecision{allowed: true, risk_level: risk, detail: "Auto-permitted (no risk)"}}
  end

  defp check_auto_permit(risk), do: {:continue, risk}

  defp check_role({:permit, decision}, _role, _tool), do: {:permit, decision}

  defp check_role({:continue, risk}, role, tool) do
    cond do
      tool.allowed_roles == [] ->
        {:continue, risk}

      role in tool.allowed_roles ->
        {:continue, risk}

      true ->
        {:deny,
         %PolicyDecision{
           allowed: false,
           risk_level: risk,
           reason: :insufficient_role,
           detail: "Role '#{role}' not in allowed roles: #{inspect(tool.allowed_roles)}"
         }}
    end
  end

  defp check_data_boundary({:permit, d}, _ctx, _tool), do: {:permit, d}
  defp check_data_boundary({:deny, d}, _ctx, _tool), do: {:deny, d}

  defp check_data_boundary({:continue, risk}, context, tool) do
    ctx_boundary = Map.get(context, :data_boundary, :authenticated_user_only)
    tool_boundary = tool.data_boundary

    boundary_order = %{authenticated_user_only: 0, team: 1, organization: 2}
    ctx_level = Map.get(boundary_order, ctx_boundary, 0)
    tool_level = Map.get(boundary_order, tool_boundary, 0)

    if ctx_level <= tool_level do
      {:continue, risk}
    else
      {:deny,
       %PolicyDecision{
         allowed: false,
         risk_level: risk,
         reason: :scope_violation,
         detail: "Data boundary '#{ctx_boundary}' exceeds tool boundary '#{tool_boundary}'"
       }}
    end
  end

  defp check_bulk_operation({:permit, d}, _ctx, _tool), do: {:permit, d}
  defp check_bulk_operation({:deny, d}, _ctx, _tool), do: {:deny, d}

  defp check_bulk_operation({:continue, risk}, context, tool) do
    record_count = Map.get(context, :record_count, 0)
    is_bulk = Map.get(context, :is_bulk, false)

    cond do
      is_bulk and Types.risk_severity(risk) >= Types.risk_severity(:medium) ->
        {:escalate, risk}

      record_count > tool.max_records ->
        {:deny,
         %PolicyDecision{
           allowed: false,
           risk_level: risk,
           reason: :data_policy_violation,
           detail: "Record count #{record_count} exceeds max #{tool.max_records}"
         }}

      true ->
        {:continue, risk}
    end
  end

  defp check_trust_ceiling({:permit, d}, _ctx), do: {:permit, d}
  defp check_trust_ceiling({:deny, d}, _ctx), do: {:deny, d}

  defp check_trust_ceiling({:escalate, risk}, _ctx) do
    {:escalate,
     %PolicyDecision{
       allowed: false,
       risk_level: risk,
       reason: :approval_required,
       detail: "Bulk operation at #{risk} risk requires approval",
       needs_approval: true
     }}
  end

  defp check_trust_ceiling({:continue, risk}, context) do
    trust = Map.get(context, :trust_ceiling, :authoritative)

    cond do
      trust == :untrusted and Types.risk_severity(risk) >= Types.risk_severity(:medium) ->
        {:deny,
         %PolicyDecision{
           allowed: false,
           risk_level: risk,
           reason: :trust_degraded,
           detail: "Trust ceiling is untrusted; #{risk} risk operations blocked"
         }}

      trust == :derived and Types.risk_severity(risk) >= Types.risk_severity(:high) ->
        {:escalate,
         %PolicyDecision{
           allowed: false,
           risk_level: risk,
           reason: :approval_required,
           detail: "Derived trust requires approval for #{risk} risk operations",
           needs_approval: true
         }}

      true ->
        {:continue, risk}
    end
  end

  defp finalize({:permit, decision}, _risk, _tool_name), do: decision
  defp finalize({:deny, decision}, _risk, _tool_name), do: decision
  defp finalize({:escalate, decision}, _risk, _tool_name), do: decision

  defp finalize({:continue, risk}, _risk, tool_name) do
    needs_approval = Types.risk_severity(risk) >= Types.risk_severity(:high)

    %PolicyDecision{
      allowed: !needs_approval,
      risk_level: risk,
      reason: if(needs_approval, do: :approval_required, else: nil),
      detail:
        if(needs_approval,
          do: "#{tool_name} at #{risk} risk requires approval",
          else: "#{tool_name} authorized at #{risk} risk"
        ),
      needs_approval: needs_approval
    }
  end
end
