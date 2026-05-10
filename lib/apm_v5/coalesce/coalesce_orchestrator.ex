defmodule ApmV5.Coalesce.CoalesceOrchestrator do
  @moduledoc """
  Central GenServer managing the lifecycle of coalesce runs.

  A coalesce run ingests one or more authoritative sources, deploys a
  max-agentic formation (4-8 squadrons, 32-128 agents) to analyse skill
  gaps, collects per-skill diffs, manages decision gates, and — upon
  approval — writes the updated SKILL.md files.

  ## State machine
  :idle → :intelligence → :analysis → :generation → :validation
        → :awaiting_gate → :applying → :complete | :cancelled | :failed

  ## ETS table
  :coalesce_runs  — keyed by run_id, stores full run state
  """

  use GenServer

  require Logger

  alias ApmV5.AgUi.EventBus
  alias ApmV5.Coalesce.{DecisionGateStore, SkillLogicEngine, SwarmCoordinator}

  @table :coalesce_runs
  @skills_path Path.expand("~/.claude/skills")

  # ── Client API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start a new coalesce run. Returns {:ok, run_id}."
  @spec start_run(map()) :: {:ok, String.t()} | {:error, term()}
  def start_run(params) do
    GenServer.call(__MODULE__, {:start_run, params})
  end

  @doc "Get the full state of a run."
  @spec get_run(String.t()) :: map() | nil
  def get_run(run_id) do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      _tid ->
        case :ets.lookup(@table, run_id) do
          [{^run_id, run}] -> run
          [] -> nil
        end
    end
  end

  @doc "List all runs, newest first."
  @spec list_runs() :: [map()]
  def list_runs do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _tid ->
        @table
        |> :ets.tab2list()
        |> Enum.map(fn {_id, run} -> run end)
        |> Enum.sort_by(& &1.started_at, :desc)
    end
  end

  @doc "Cancel an in-progress run."
  @spec cancel_run(String.t()) :: :ok | {:error, :not_found | :already_done}
  def cancel_run(run_id) do
    GenServer.call(__MODULE__, {:cancel_run, run_id})
  end

  @doc "Apply approved diffs for a run (after G3 gate approval)."
  @spec apply_run(String.t()) :: {:ok, map()} | {:error, term()}
  def apply_run(run_id) do
    GenServer.call(__MODULE__, {:apply_run, run_id}, 120_000)
  end

  @doc "Get proposed diffs for a run."
  @spec get_diffs(String.t()) :: {:ok, [map()]} | {:error, :not_found}
  def get_diffs(run_id) do
    case get_run(run_id) do
      nil -> {:error, :not_found}
      run -> {:ok, run[:diffs] || []}
    end
  end

  @doc "Count pending gate decisions across all runs."
  @spec pending_gate_count() :: non_neg_integer()
  def pending_gate_count do
    DecisionGateStore.pending_count()
  end

  # ── GenServer Callbacks ───────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:start_run, params}, _from, state) do
    run_id = generate_run_id()

    run = %{
      run_id: run_id,
      status: :intelligence,
      dry_run: Map.get(params, "dry_run", false),
      auto_approve: Map.get(params, "auto_approve", false),
      sources: Map.get(params, "sources", []),
      scope: Map.get(params, "scope", "all skills"),
      squadrons: Map.get(params, "squadrons", 6),
      agent_count: Map.get(params, "agent_count", 64),
      started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      completed_at: nil,
      gates: %{},
      diffs: [],
      affected_skills: [],
      swarm_agents: [],
      formation_id: "fmt-coalesce-#{run_id}",
      result: nil,
      error: nil
    }

    :ets.insert(@table, {run_id, run})

    Logger.info("[Coalesce] Run #{run_id} started — scope: #{run.scope}")

    _broadcast_run_event("coalesce_run_started", run)

    # Kick off intelligence phase asynchronously
    send(self(), {:phase_intelligence, run_id})

    {:reply, {:ok, run_id}, state}
  end

  def handle_call({:cancel_run, run_id}, _from, state) do
    case get_run(run_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: done} when done in [:complete, :cancelled, :failed] ->
        {:reply, {:error, :already_done}, state}

      run ->
        updated = %{run | status: :cancelled, completed_at: DateTime.utc_now() |> DateTime.to_iso8601()}
        :ets.insert(@table, {run_id, updated})
        SwarmCoordinator.stop_swarms(run.formation_id)
        _broadcast_run_event("coalesce_run_cancelled", updated)
        {:reply, :ok, state}
    end
  end

  def handle_call({:apply_run, run_id}, _from, state) do
    case get_run(run_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: :awaiting_gate} = run ->
        result = _apply_diffs(run)
        updated = %{run |
          status: :complete,
          completed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          result: result
        }
        :ets.insert(@table, {run_id, updated})
        _broadcast_run_event("coalesce_run_applied", updated)
        {:reply, {:ok, result}, state}

      %{status: status} ->
        {:reply, {:error, {:wrong_status, status}}, state}
    end
  end

  # ── Phase Handlers ────────────────────────────────────────────────────────

  @impl true
  def handle_info({:phase_intelligence, run_id}, state) do
    with %{} = run <- get_run(run_id),
         false <- run.status == :cancelled do
      Logger.info("[Coalesce] #{run_id} — Phase 1: Intelligence")

      # Spawn intelligence swarm
      intel_results = _run_intelligence_phase(run)

      # G1: confidence gate (auto)
      confidence = intel_results[:source_confidence] || 0.0
      _register_gate(run_id, "G1", :auto, %{
        description: "Source confidence check (≥ 0.70 to proceed)",
        confidence: confidence,
        threshold: 0.70
      })

      if confidence >= 0.70 or run.auto_approve do
        DecisionGateStore.auto_approve("#{run_id}:G1", %{confidence: confidence})

        updated = %{run |
          status: :analysis,
          affected_skills: intel_results[:affected_skills] || []
        }
        :ets.insert(@table, {run_id, updated})
        send(self(), {:phase_analysis, run_id, intel_results})
      else
        updated = %{run | status: :failed, error: "Source confidence #{confidence} below threshold 0.70"}
        :ets.insert(@table, {run_id, updated})
        _broadcast_run_event("coalesce_run_failed", updated)
      end
    end

    {:noreply, state}
  end

  def handle_info({:phase_analysis, run_id, intel_results}, state) do
    with %{} = run <- get_run(run_id),
         false <- run.status == :cancelled do
      Logger.info("[Coalesce] #{run_id} — Phase 2: Analysis")

      affected = run.affected_skills
      swarm_count = length(affected) * 3

      # G2: scope confirmation (human unless auto_approve)
      gate_type = if run.auto_approve, do: :auto, else: :human
      _register_gate(run_id, "G2", gate_type, %{
        description: "#{length(affected)} skills affected. Proceed with #{swarm_count} swarm agents?",
        affected_count: length(affected),
        swarm_count: swarm_count
      })

      # If auto_approve, proceed immediately; otherwise wait for gate decision
      if run.auto_approve do
        DecisionGateStore.auto_approve("#{run_id}:G2", %{actor: "auto_approve"})
        send(self(), {:phase_generation, run_id, intel_results})
      else
        _broadcast_run_event("coalesce_gate_pending", %{run_id: run_id, gate: "G2"})
        # Gate G2 decision will call :gate_decided message
      end
    end

    {:noreply, state}
  end

  def handle_info({:phase_generation, run_id, intel_results}, state) do
    with %{} = run <- get_run(run_id),
         false <- run.status == :cancelled do
      Logger.info("[Coalesce] #{run_id} — Phase 3: Generation Formation")

      diffs = _run_generation_phase(run, intel_results)

      # G3: diff preview (always human)
      _register_gate(run_id, "G3", :human, %{
        description: "Review #{length(diffs)} proposed skill diffs before applying",
        diff_count: length(diffs),
        diffs_summary: Enum.map(diffs, &Map.take(&1, [:skill_name, :impact, :confidence]))
      })

      updated = %{run | status: :awaiting_gate, diffs: diffs}
      :ets.insert(@table, {run_id, updated})

      _broadcast_run_event("coalesce_gate_pending", %{run_id: run_id, gate: "G3"})

      if run.auto_approve do
        all_confident = Enum.all?(diffs, &(&1.confidence >= 0.80))
        if all_confident do
          DecisionGateStore.auto_approve("#{run_id}:G3", %{actor: "auto_approve"})
          send(self(), {:phase_validation, run_id})
        end
      end
    end

    {:noreply, state}
  end

  def handle_info({:phase_validation, run_id}, state) do
    with %{} = run <- get_run(run_id),
         false <- run.status == :cancelled do
      Logger.info("[Coalesce] #{run_id} — Phase 4: Validation")

      validation = _run_validation_phase(run)
      all_pass = Enum.all?(validation, &(&1.passes))
      avg_confidence = validation
        |> Enum.map(& &1.confidence)
        |> then(fn scores -> if Enum.empty?(scores), do: 0.0, else: Enum.sum(scores) / length(scores) end)

      gate_type = if avg_confidence >= 0.85 or run.auto_approve, do: :auto, else: :human
      _register_gate(run_id, "G4", gate_type, %{
        description: "Validation complete — #{length(Enum.filter(validation, & &1.passes))}/#{length(validation)} passed",
        all_pass: all_pass,
        avg_confidence: avg_confidence,
        results: validation
      })

      if gate_type == :auto and (all_pass or run.auto_approve) do
        DecisionGateStore.auto_approve("#{run_id}:G4", %{avg_confidence: avg_confidence})
        send(self(), {:do_apply, run_id})
      else
        _broadcast_run_event("coalesce_gate_pending", %{run_id: run_id, gate: "G4"})
      end
    end

    {:noreply, state}
  end

  def handle_info({:do_apply, run_id}, state) do
    case get_run(run_id) do
      nil -> :ok
      run ->
        result = _apply_diffs(run)
        updated = %{run |
          status: :complete,
          completed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          result: result
        }
        :ets.insert(@table, {run_id, updated})
        _broadcast_run_event("coalesce_run_applied", updated)
    end

    {:noreply, state}
  end

  def handle_info({:gate_decided, run_id, gate_id, :approved}, state) do
    with %{} = _run <- get_run(run_id) do
      case gate_id do
        "G2" -> send(self(), {:phase_generation, run_id, %{}})
        "G3" -> send(self(), {:phase_validation, run_id})
        "G4" -> send(self(), {:do_apply, run_id})
        _ -> :ok
      end
    end

    {:noreply, state}
  end

  def handle_info({:gate_decided, run_id, gate_id, :rejected}, state) do
    with %{} = run <- get_run(run_id) do
      updated = %{run |
        status: :cancelled,
        completed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        error: "Gate #{gate_id} rejected by user"
      }
      :ets.insert(@table, {run_id, updated})
      _broadcast_run_event("coalesce_run_cancelled", updated)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private: Phase Implementations ────────────────────────────────────────

  defp _run_intelligence_phase(run) do
    sources = run.sources
    scope = run.scope

    # Delegate to SkillLogicEngine for source analysis
    source_analysis = SkillLogicEngine.analyze_sources(sources)

    # Determine affected skills from scope + source findings
    affected = SkillLogicEngine.resolve_affected_skills(@skills_path, scope, source_analysis)

    Logger.info("[Coalesce] Intelligence: #{length(affected)} skills in scope, confidence=#{source_analysis[:confidence]}")

    %{
      source_analysis: source_analysis,
      source_confidence: source_analysis[:confidence] || 0.0,
      frameworks: source_analysis[:frameworks] || [],
      insights: source_analysis[:insights] || [],
      affected_skills: affected
    }
  end

  defp _run_generation_phase(run, intel_results) do
    affected = run.affected_skills
    formation_id = run.formation_id

    # Deploy per-skill swarms via SwarmCoordinator
    SwarmCoordinator.deploy_swarms(formation_id, affected, %{
      findings: intel_results[:insights] || [],
      frameworks: intel_results[:frameworks] || [],
      dry_run: run.dry_run
    })

    # Generate diffs for each affected skill
    affected
    |> Enum.map(fn skill_name ->
      SkillLogicEngine.generate_diff(skill_name, @skills_path, intel_results)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp _run_validation_phase(run) do
    run.diffs
    |> Enum.map(fn diff ->
      SkillLogicEngine.validate_diff(diff)
    end)
  end

  defp _apply_diffs(%{dry_run: true} = run) do
    Logger.info("[Coalesce] DRY RUN — skipping file writes for #{run.run_id}")
    %{applied: 0, skipped: length(run.diffs), dry_run: true}
  end

  defp _apply_diffs(run) do
    results = Enum.map(run.diffs, fn diff ->
      if diff.approved && diff.confidence >= 0.70 do
        path = Path.join(@skills_path, "#{diff.skill_name}/SKILL.md")
        File.write!(path, diff.new_content)
        {:applied, diff.skill_name}
      else
        {:skipped, diff.skill_name}
      end
    end)

    applied = Enum.count(results, fn {status, _} -> status == :applied end)
    skipped = Enum.count(results, fn {status, _} -> status == :skipped end)

    # Refresh skills registry cache
    ApmV5.SkillsRegistryStore.refresh_all()

    Logger.info("[Coalesce] Applied #{applied} skill updates, skipped #{skipped}")
    %{applied: applied, skipped: skipped, dry_run: false}
  end

  # ── Private: Helpers ───────────────────────────────────────────────────────

  defp _register_gate(run_id, gate_id, type, metadata) do
    DecisionGateStore.register_gate("#{run_id}:#{gate_id}", %{
      run_id: run_id,
      gate_id: gate_id,
      type: type,
      metadata: metadata
    })
  end

  defp _broadcast_run_event(event_name, payload) do
    EventBus.publish("CUSTOM", %{
      name: event_name,
      agent_id: "coalesce-orchestrator",
      value: payload
    })

    Phoenix.PubSub.broadcast(
      ApmV5.PubSub,
      "apm:coalesce",
      {String.to_atom(event_name), payload}
    )
  end

  defp generate_run_id do
    ts = DateTime.utc_now() |> DateTime.to_unix()
    rand = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    "crs-#{ts}-#{rand}"
  end
end
