defmodule Apm.Plugins.Coalesce.CoalescePlugin do
  @moduledoc """
  APM Plugin exposing coalesce actions to the plugin engine.

  Actions:
  - "start"    — start a new coalesce run
  - "status"   — get run status
  - "list"     — list all runs
  - "decide"   — approve/reject/defer a gate
  - "apply"    — apply approved diffs
  - "cancel"   — cancel a run
  - "preview"  — dry-run preview (no state change)
  """

  @behaviour Apm.Plugins.PluginBehaviour

  alias Apm.Coalesce.{CoalesceOrchestrator, DecisionGateStore, SkillLogicEngine, SwarmCoordinator, SourceFetcher}

  @impl true
  def plugin_name, do: "coalesce"

  @impl true
  def plugin_description, do: "Skill logic coalescer — ingest sources, deploy formation, manage decision gates, apply refined skills"

  @impl true
  def plugin_version, do: "1.0.0"

  @impl true
  def list_endpoints do
    [
      %{action: "start", description: "Start a coalesce run", params: %{sources: "list", scope: "string", dry_run: "bool", auto_approve: "bool"}},
      %{action: "status", description: "Get run status", params: %{run_id: "string"}},
      %{action: "list", description: "List all runs with pending gate count", params: %{}},
      %{action: "decide", description: "Approve/reject/defer a gate", params: %{run_id: "string", gate_id: "string", decision: "approve|reject|defer", reason: "string"}},
      %{action: "apply", description: "Apply approved diffs for a run", params: %{run_id: "string"}},
      %{action: "cancel", description: "Cancel an in-progress run", params: %{run_id: "string"}},
      %{action: "preview", description: "Dry-run preview — formation plan + affected skills without starting a run", params: %{sources: "list", scope: "string"}}
    ]
  end

  @impl true
  def handle_action("start", params, _opts) do
    case CoalesceOrchestrator.start_run(params) do
      {:ok, run_id} ->
        run = CoalesceOrchestrator.get_run(run_id)
        {:ok, %{run_id: run_id, status: run.status, formation_id: run.formation_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_action("status", %{"run_id" => run_id}, _opts) do
    case CoalesceOrchestrator.get_run(run_id) do
      nil -> {:error, {:not_found, run_id}}
      run ->
        gates = DecisionGateStore.list_for_run(run_id)
        {:ok, %{run: run, gates: gates}}
    end
  end

  def handle_action("list", _params, _opts) do
    runs = CoalesceOrchestrator.list_runs()
    pending = DecisionGateStore.pending_count()
    {:ok, %{runs: runs, total: length(runs), pending_gates: pending}}
  end

  def handle_action("decide", %{"run_id" => run_id, "gate_id" => gate_id} = params, _opts) do
    composite_id = "#{run_id}:#{gate_id}"
    decision = params["decision"] || "approve"
    reason = params["reason"] || ""

    result = case decision do
      "approve" -> DecisionGateStore.approve(composite_id, %{approver: "plugin"})
      "reject" -> DecisionGateStore.reject(composite_id, reason)
      "defer" -> DecisionGateStore.defer(composite_id, reason)
      _ -> {:error, {:invalid_decision, decision}}
    end

    case result do
      :ok -> {:ok, %{composite_id: composite_id, decision: decision, status: "accepted"}}
      error -> error
    end
  end

  def handle_action("apply", %{"run_id" => run_id}, _opts) do
    CoalesceOrchestrator.apply_run(run_id)
  end

  def handle_action("cancel", %{"run_id" => run_id}, _opts) do
    case CoalesceOrchestrator.cancel_run(run_id) do
      :ok -> {:ok, %{run_id: run_id, status: "cancelled"}}
      error -> error
    end
  end

  def handle_action("preview", params, _opts) do
    sources = params["sources"] || []
    scope = params["scope"] || "product management"
    formation_id = "fmt-preview-#{System.system_time(:second)}"
    skills_path = Path.expand("~/.claude/skills")

    fetched = SourceFetcher.fetch_all(sources)
    analysis = SkillLogicEngine.analyze_sources(fetched)
    affected = SkillLogicEngine.resolve_affected_skills(skills_path, scope, analysis)
    plan = SwarmCoordinator.build_formation_plan(formation_id, affected, %{})

    {:ok, %{
      source_confidence: analysis[:confidence],
      frameworks: analysis[:frameworks],
      affected_skills: affected,
      formation_plan: plan,
      preview: true
    }}
  end

  def handle_action(action, _params, _opts) do
    {:error, {:unknown_action, action}}
  end

  @impl true
  def supervisor_children, do: [Apm.Coalesce.CoalesceSupervisor]

  @impl true
  def default_enabled?, do: true
end
