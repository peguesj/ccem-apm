defmodule ApmV5Web.V2.CoalesceController do
  @moduledoc """
  REST API for coalesce runs and decision gates.

  Endpoints:
    POST   /api/v2/coalesce/start               — start a new run
    GET    /api/v2/coalesce                      — list all runs
    GET    /api/v2/coalesce/:id                  — get run status
    GET    /api/v2/coalesce/:id/diff             — preview proposed diffs
    POST   /api/v2/coalesce/:id/gate/:gate_id/decide — approve/reject/defer a gate
    POST   /api/v2/coalesce/:id/apply            — apply approved diffs
    DELETE /api/v2/coalesce/:id                  — cancel a run
  """

  use ApmV5Web, :controller

  alias ApmV5.Coalesce.{CoalesceOrchestrator, DecisionGateStore, SkillLogicEngine, SwarmCoordinator, SourceFetcher}

  # POST /api/v2/coalesce/start
  def start(conn, params) do
    sources = params["sources"] || []
    scope = params["scope"] || params["context"] || "all skills"
    dry_run = params["dry_run"] == true or params["dry_run"] == "true"
    auto_approve = params["auto_approve"] == true or params["auto_approve"] == "true"
    squadrons = params["squadrons"] || 6
    agent_count = params["agent_count"] || 64

    run_params = %{
      "sources" => sources,
      "scope" => scope,
      "dry_run" => dry_run,
      "auto_approve" => auto_approve,
      "squadrons" => squadrons,
      "agent_count" => agent_count
    }

    case CoalesceOrchestrator.start_run(run_params) do
      {:ok, run_id} ->
        run = CoalesceOrchestrator.get_run(run_id)

        conn
        |> put_status(202)
        |> json(%{
          run_id: run_id,
          status: run.status,
          formation_id: run.formation_id,
          dry_run: dry_run,
          scope: scope,
          source_count: length(sources),
          dashboard_url: "http://localhost:3032/coalesce?run=#{run_id}",
          message: "Coalesce run started. Monitor at /coalesce or poll GET /api/v2/coalesce/#{run_id}"
        })

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{error: inspect(reason)})
    end
  end

  # GET /api/v2/coalesce
  def index(conn, _params) do
    runs = CoalesceOrchestrator.list_runs()
    pending_gates = DecisionGateStore.pending_count()

    json(conn, %{
      runs: Enum.map(runs, &_run_summary/1),
      total: length(runs),
      pending_gates: pending_gates
    })
  end

  # GET /api/v2/coalesce/:id
  def show(conn, %{"id" => run_id}) do
    case CoalesceOrchestrator.get_run(run_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "run not found"})

      run ->
        gates = DecisionGateStore.list_for_run(run_id)

        json(conn, %{
          run: _run_detail(run),
          gates: Enum.map(gates, &_gate_summary/1),
          pending_gate_count: Enum.count(gates, & &1.status == :pending)
        })
    end
  end

  # GET /api/v2/coalesce/:id/diff
  def diff(conn, %{"id" => run_id}) do
    case CoalesceOrchestrator.get_diffs(run_id) do
      {:ok, diffs} ->
        json(conn, %{
          run_id: run_id,
          diff_count: length(diffs),
          diffs: Enum.map(diffs, &_diff_summary/1)
        })

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "run not found"})
    end
  end

  # POST /api/v2/coalesce/:id/gate/:gate_id/decide
  def gate_decide(conn, %{"id" => run_id, "gate_id" => gate_id} = params) do
    composite_id = "#{run_id}:#{gate_id}"
    decision = params["decision"] || "approve"
    reason = params["reason"] || ""
    approver = params["approver"] || "api"

    result = case decision do
      "approve" -> DecisionGateStore.approve(composite_id, %{approver: approver, reason: reason})
      "reject" -> DecisionGateStore.reject(composite_id, reason)
      "defer" -> DecisionGateStore.defer(composite_id, reason)
      _ -> {:error, {:invalid_decision, decision}}
    end

    case result do
      :ok ->
        json(conn, %{
          composite_id: composite_id,
          decision: decision,
          status: "accepted",
          message: "Gate #{gate_id} #{decision}d"
        })

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "gate not found: #{composite_id}"})

      {:error, :not_pending} ->
        conn |> put_status(409) |> json(%{error: "gate is not in pending state"})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  # POST /api/v2/coalesce/:id/apply
  def apply_run(conn, %{"id" => run_id}) do
    case CoalesceOrchestrator.apply_run(run_id) do
      {:ok, result} ->
        json(conn, %{
          run_id: run_id,
          status: "applied",
          applied: result.applied,
          skipped: result.skipped,
          dry_run: result.dry_run
        })

      {:error, {:wrong_status, status}} ->
        conn
        |> put_status(409)
        |> json(%{
          error: "Run is in #{status} status — must be :awaiting_gate to apply",
          hint: "Approve G3 gate first via POST /api/v2/coalesce/#{run_id}/gate/G3/decide"
        })

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "run not found"})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  # DELETE /api/v2/coalesce/:id
  def cancel(conn, %{"id" => run_id}) do
    case CoalesceOrchestrator.cancel_run(run_id) do
      :ok ->
        json(conn, %{run_id: run_id, status: "cancelled"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "run not found"})

      {:error, :already_done} ->
        conn |> put_status(409) |> json(%{error: "run already completed or cancelled"})
    end
  end

  # ── Dry-Run Preview Endpoint ───────────────────────────────────────────────

  # POST /api/v2/coalesce/preview
  def preview(conn, params) do
    sources = params["sources"] || []
    scope = params["scope"] || params["context"] || "product management"

    # Quick formation plan without starting a real run
    formation_id = "fmt-preview-#{System.system_time(:second)}"
    skills_path = Path.expand("~/.claude/skills")

    fetched_sources = SourceFetcher.fetch_all(sources)
    analysis = SkillLogicEngine.analyze_sources(fetched_sources)
    affected_skills = SkillLogicEngine.resolve_affected_skills(skills_path, scope, analysis)
    formation_plan = SwarmCoordinator.build_formation_plan(formation_id, affected_skills, %{squadrons: 6})

    json(conn, %{
      preview: true,
      sources_analyzed: length(fetched_sources),
      source_confidence: analysis[:confidence] || 0.0,
      frameworks_detected: analysis[:frameworks] || [],
      domain_signals: analysis[:domain_signals] || [],
      affected_skill_count: length(affected_skills),
      affected_skills: affected_skills,
      formation_plan: formation_plan,
      gate_schedule: [
        %{gate: "G1", type: "auto", condition: "Source confidence ≥ 0.70"},
        %{gate: "G2", type: "human", condition: "Scope confirmation before formation deploy"},
        %{gate: "G3", type: "human", condition: "Diff preview — approve before applying"},
        %{gate: "G4", type: "auto or human", condition: "Validation: auto if avg_confidence ≥ 0.85"}
      ],
      estimated_duration: "#{_estimate_duration_minutes(formation_plan.total_agents)} minutes",
      dry_run_note: "This is a preview — no files will be written until /apply is called after G3 approval"
    })
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp _run_summary(run) do
    %{
      run_id: run.run_id,
      status: run.status,
      scope: run.scope,
      dry_run: run.dry_run,
      affected_skill_count: length(run.affected_skills),
      diff_count: length(run.diffs),
      started_at: run.started_at,
      completed_at: run.completed_at
    }
  end

  defp _run_detail(run) do
    %{
      run_id: run.run_id,
      status: run.status,
      formation_id: run.formation_id,
      scope: run.scope,
      dry_run: run.dry_run,
      auto_approve: run.auto_approve,
      sources: run.sources,
      affected_skills: run.affected_skills,
      diff_count: length(run.diffs),
      started_at: run.started_at,
      completed_at: run.completed_at,
      result: run.result,
      error: run.error
    }
  end

  defp _gate_summary(gate) do
    %{
      composite_id: gate.composite_id,
      gate_id: gate.gate_id,
      type: gate.type,
      status: gate.status,
      metadata: gate.metadata,
      registered_at: gate.registered_at,
      decided_at: gate.decided_at,
      decided_by: gate.decided_by
    }
  end

  defp _diff_summary(diff) do
    %{
      skill_name: diff.skill_name,
      impact: diff.impact,
      confidence: diff.confidence,
      approved: diff.approved,
      addition_count: length(diff.additions),
      additions: Enum.map(diff.additions, fn a ->
        %{section: a.section, type: a.type}
      end),
      generated_at: diff.generated_at
    }
  end

  defp _estimate_duration_minutes(agent_count) do
    # Rough heuristic: ~30s per agent in parallel, 6 waves
    div(agent_count * 30, 60) + 5
  end
end
