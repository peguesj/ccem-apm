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
  alias ApmV5.Auth.PolicyPriorityResolver

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
    # Multi-rule conflict resolution path (auth-v10.1-s4 / CP-294):
    # When caller provides :matching_rules list, resolve via PolicyPriorityResolver.
    resolved_rule =
      case Map.get(context, :matching_rules) do
        [_ | _] = rules ->
          strategy = PolicyPriorityResolver.configured_strategy()
          PolicyPriorityResolver.resolve(rules, strategy)

        _ ->
          Map.get(context, :policy_rule, :none)
      end

    # Permanent policy rule takes absolute priority over all other checks.
    case resolved_rule do
      :always_allow ->
        %PolicyDecision{
          allowed: true,
          needs_approval: false,
          risk_level: :none,
          reason: :always_allow_rule,
          detail: "Permanent allow rule for #{tool_name}"
        }

      :always_deny ->
        %PolicyDecision{
          allowed: false,
          needs_approval: false,
          risk_level: :high,
          reason: :always_deny_rule,
          detail: "Permanent deny rule for #{tool_name}"
        }

      :none ->
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

  @doc """
  Derives a risk level from MCP ToolAnnotations (Protocol 2025-03-26).

  ## Annotation semantics
  - `readOnly: true` → :none (safe read, no side effects)
  - `destructive: true` → :critical (irreversible writes)
  - `openWorld: true` + not readOnly → :high (unbounded external scope)
  - `idempotent: true` + not destructive → :medium (repeatable, recoverable)
  - default (no annotations) → :low

  Both string and atom keys are accepted.
  """
  @spec from_mcp_annotations(map()) :: Types.risk_level()
  def from_mcp_annotations(annotations) when is_map(annotations) do
    read_only   = Map.get(annotations, "readOnly",    Map.get(annotations, :readOnly,    false))
    destructive = Map.get(annotations, "destructive", Map.get(annotations, :destructive, false))
    open_world  = Map.get(annotations, "openWorld",   Map.get(annotations, :openWorld,   false))
    idempotent  = Map.get(annotations, "idempotent",  Map.get(annotations, :idempotent,  false))

    cond do
      read_only   -> :none
      destructive -> :critical
      open_world  -> :high
      idempotent  -> :medium
      true        -> :low
    end
  end

  def from_mcp_annotations(_), do: :low

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
    bash_risk =
      case tool_name do
        "Bash" ->
          command = get_in(context, [:params, "command"]) || ""

          if destructive_command?(command) do
            # KRI: critical_command_rate
            agent_id   = Map.get(context, :agent_id, "unknown")
            cmd_sig    = String.slice(command, 0, 120)

            :telemetry.execute(
              [:apm_v5, :governance, :critical_command_rate],
              %{count: 1},
              %{tool_name: tool_name, agent_id: agent_id, command_signature: cmd_sig}
            )

            :critical
          else
            base_risk
          end

        _ ->
          base_risk
      end

    # Apply MCP ToolAnnotations if provided — take the higher risk.
    # If annotations also produce :critical emit KRI for annotation path.
    mcp_annotations = Map.get(context, :mcp_annotations)

    if is_map(mcp_annotations) and map_size(mcp_annotations) > 0 do
      annotation_risk = from_mcp_annotations(mcp_annotations)

      final_risk =
        if Types.risk_severity(annotation_risk) > Types.risk_severity(bash_risk),
          do: annotation_risk,
          else: bash_risk

      if final_risk == :critical and bash_risk != :critical do
        # Annotation-driven :critical — emit KRI if not already emitted above
        agent_id = Map.get(context, :agent_id, "unknown")

        :telemetry.execute(
          [:apm_v5, :governance, :critical_command_rate],
          %{count: 1},
          %{tool_name: tool_name, agent_id: agent_id, command_signature: "mcp_annotation_destructive"}
        )
      end

      final_risk
    else
      bash_risk
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
