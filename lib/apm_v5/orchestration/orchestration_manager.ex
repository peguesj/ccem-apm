defmodule ApmV5.Orchestration.OrchestrationManager do
  @moduledoc """
  GenServer managing active orchestration runs.

  Each run represents a DAG-based workflow execution. Steps are advanced
  based on dependency resolution — a step can only run when all of its
  upstream dependencies have completed.

  ## ETS Table

  - Name: `:orchestration_runs`
  - Key: run_id (String.t)
  - Value: run map

  ## PubSub

  Broadcasts on `"apm:orchestration"` for all state mutations.
  """

  use GenServer
  require Logger

  @table :orchestration_runs
  @pubsub_topic "apm:orchestration"

  # ── Types ──────────────────────────────────────────────────────────────────

  @type step_status :: :pending | :running | :completed | :failed | :skipped

  @type step :: %{
          id: String.t(),
          status: step_status(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          payload: map(),
          result: map() | nil
        }

  @type run :: %{
          id: String.t(),
          workflow_id: String.t(),
          status: :pending | :running | :completed | :failed | :cancelled,
          steps: %{String.t() => step()},
          edges: [%{source: String.t(), target: String.t()}],
          current_wave: non_neg_integer(),
          params: map(),
          dry_run: boolean(),
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  # ── Public API ─────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start a new orchestration run for a workflow."
  @spec start_run(String.t(), map()) :: {:ok, run()} | {:error, term()}
  def start_run(workflow_id, params \\ %{}) do
    GenServer.call(__MODULE__, {:start_run, workflow_id, params})
  end

  @doc "Advance a step in a run with the given result."
  @spec advance_step(String.t(), String.t(), map()) :: {:ok, run()} | {:error, term()}
  def advance_step(run_id, step_id, result \\ %{}) do
    GenServer.call(__MODULE__, {:advance_step, run_id, step_id, result})
  end

  @doc "Mark a step as failed."
  @spec fail_step(String.t(), String.t(), term()) :: {:ok, run()} | {:error, term()}
  def fail_step(run_id, step_id, reason \\ "unknown") do
    GenServer.call(__MODULE__, {:fail_step, run_id, step_id, reason})
  end

  @doc "Skip a step."
  @spec skip_step(String.t(), String.t()) :: {:ok, run()} | {:error, term()}
  def skip_step(run_id, step_id) do
    GenServer.call(__MODULE__, {:skip_step, run_id, step_id})
  end

  @doc "Cancel a run."
  @spec cancel_run(String.t()) :: {:ok, run()} | {:error, term()}
  def cancel_run(run_id) do
    GenServer.call(__MODULE__, {:cancel_run, run_id})
  end

  @doc "Get a run by ID."
  @spec get_run(String.t()) :: run() | nil
  def get_run(run_id) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, run}] -> run
      [] -> nil
    end
  end

  @doc "List all active runs."
  @spec list_active_runs() :: [run()]
  def list_active_runs do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, run} -> run end)
    |> Enum.filter(&(&1.status in [:pending, :running]))
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  end

  @doc "List all runs (active and completed)."
  @spec list_all_runs() :: [run()]
  def list_all_runs do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, run} -> run end)
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  end

  @doc """
  Determine which steps can execute next for a run.
  A step is ready when all its upstream dependencies are completed.
  """
  @spec next_steps(String.t()) :: [String.t()]
  def next_steps(run_id) do
    case get_run(run_id) do
      nil -> []
      run -> compute_next_steps(run)
    end
  end

  @doc "Returns the PubSub topic for orchestration events."
  @spec pubsub_topic() :: String.t()
  def pubsub_topic, do: @pubsub_topic

  # ── GenServer Callbacks ────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:start_run, workflow_id, params}, _from, state) do
    case resolve_workflow(workflow_id) do
      nil ->
        {:reply, {:error, {:workflow_not_found, workflow_id}}, state}

      workflow ->
        dry_run = Map.get(params, :dry_run, false) || Map.get(params, "dry_run", false)
        run = build_run(workflow_id, workflow, params, dry_run)

        if dry_run do
          # Dry run: return planned execution order without persisting
          execution_order = compute_execution_order(run)
          dry_result = Map.put(run, :execution_order, execution_order)
          {:reply, {:ok, dry_result}, state}
        else
          :ets.insert(@table, {run.id, run})
          broadcast(:run_started, run)
          Logger.info("[OrchestrationManager] Started run #{run.id} for workflow #{workflow_id}")
          {:reply, {:ok, run}, state}
        end
    end
  end

  @impl true
  def handle_call({:advance_step, run_id, step_id, result}, _from, state) do
    case get_run(run_id) do
      nil ->
        {:reply, {:error, {:run_not_found, run_id}}, state}

      run ->
        case Map.get(run.steps, step_id) do
          nil ->
            {:reply, {:error, {:step_not_found, step_id}}, state}

          step when step.status in [:pending, :running] ->
            now = DateTime.utc_now()

            updated_step = %{
              step
              | status: :completed,
                started_at: step.started_at || now,
                completed_at: now,
                result: result
            }

            updated_run =
              run
              |> put_in([Access.key(:steps), step_id], updated_step)
              |> Map.put(:updated_at, now)
              |> maybe_complete_run()

            :ets.insert(@table, {run_id, updated_run})
            broadcast(:step_completed, %{run: updated_run, step_id: step_id})
            {:reply, {:ok, updated_run}, state}

          step ->
            {:reply, {:error, {:invalid_transition, step.status, :completed}}, state}
        end
    end
  end

  @impl true
  def handle_call({:fail_step, run_id, step_id, reason}, _from, state) do
    case get_run(run_id) do
      nil ->
        {:reply, {:error, {:run_not_found, run_id}}, state}

      run ->
        case Map.get(run.steps, step_id) do
          nil ->
            {:reply, {:error, {:step_not_found, step_id}}, state}

          step when step.status in [:pending, :running] ->
            now = DateTime.utc_now()

            updated_step = %{
              step
              | status: :failed,
                started_at: step.started_at || now,
                completed_at: now,
                result: %{error: reason}
            }

            updated_run =
              run
              |> put_in([Access.key(:steps), step_id], updated_step)
              |> Map.put(:updated_at, now)
              |> Map.put(:status, :failed)

            :ets.insert(@table, {run_id, updated_run})
            broadcast(:step_failed, %{run: updated_run, step_id: step_id, reason: reason})
            {:reply, {:ok, updated_run}, state}

          step ->
            {:reply, {:error, {:invalid_transition, step.status, :failed}}, state}
        end
    end
  end

  @impl true
  def handle_call({:skip_step, run_id, step_id}, _from, state) do
    case get_run(run_id) do
      nil ->
        {:reply, {:error, {:run_not_found, run_id}}, state}

      run ->
        case Map.get(run.steps, step_id) do
          nil ->
            {:reply, {:error, {:step_not_found, step_id}}, state}

          step when step.status == :pending ->
            now = DateTime.utc_now()

            updated_step = %{step | status: :skipped, completed_at: now}

            updated_run =
              run
              |> put_in([Access.key(:steps), step_id], updated_step)
              |> Map.put(:updated_at, now)
              |> maybe_complete_run()

            :ets.insert(@table, {run_id, updated_run})
            broadcast(:step_skipped, %{run: updated_run, step_id: step_id})
            {:reply, {:ok, updated_run}, state}

          step ->
            {:reply, {:error, {:invalid_transition, step.status, :skipped}}, state}
        end
    end
  end

  @impl true
  def handle_call({:cancel_run, run_id}, _from, state) do
    case get_run(run_id) do
      nil ->
        {:reply, {:error, {:run_not_found, run_id}}, state}

      run when run.status in [:pending, :running] ->
        now = DateTime.utc_now()
        updated_run = %{run | status: :cancelled, updated_at: now}
        :ets.insert(@table, {run_id, updated_run})
        broadcast(:run_cancelled, updated_run)
        {:reply, {:ok, updated_run}, state}

      run ->
        {:reply, {:error, {:invalid_transition, run.status, :cancelled}}, state}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp resolve_workflow(workflow_id) do
    ApmV5.WorkflowRegistry.get_workflow(workflow_id)
  end

  defp build_run(workflow_id, workflow, params, dry_run) do
    now = DateTime.utc_now()
    run_id = "run-#{workflow_id}-#{:erlang.unique_integer([:positive])}"

    steps =
      (workflow[:steps] || workflow["steps"] || [])
      |> Enum.map(fn step ->
        step_id = step[:id] || step["id"]

        {step_id,
         %{
           id: step_id,
           status: :pending,
           started_at: nil,
           completed_at: nil,
           payload: Map.drop(step, [:id, :status, "id", "status"]),
           result: nil
         }}
      end)
      |> Map.new()

    edges =
      (workflow[:edges] || workflow["edges"] || [])
      |> Enum.map(fn edge ->
        %{
          source: edge[:source] || edge["source"] || edge[:from] || edge["from"],
          target: edge[:target] || edge["target"] || edge[:to] || edge["to"],
          label: edge[:label] || edge["label"] || edge[:condition] || edge["condition"]
        }
      end)

    %{
      id: run_id,
      workflow_id: workflow_id,
      status: :pending,
      steps: steps,
      edges: edges,
      current_wave: 0,
      params: Map.drop(params, [:dry_run, "dry_run"]),
      dry_run: dry_run,
      created_at: now,
      updated_at: now
    }
  end

  defp compute_next_steps(run) do
    completed_ids =
      run.steps
      |> Enum.filter(fn {_id, s} -> s.status in [:completed, :skipped] end)
      |> Enum.map(fn {id, _s} -> id end)
      |> MapSet.new()

    run.steps
    |> Enum.filter(fn {_id, s} -> s.status == :pending end)
    |> Enum.filter(fn {step_id, _s} ->
      # All upstream dependencies must be satisfied
      upstream =
        run.edges
        |> Enum.filter(fn e -> e.target == step_id end)
        |> Enum.map(fn e -> e.source end)

      Enum.all?(upstream, &MapSet.member?(completed_ids, &1))
    end)
    |> Enum.map(fn {id, _s} -> id end)
  end

  defp compute_execution_order(run) do
    do_compute_order(run, [], MapSet.new())
  end

  defp do_compute_order(run, acc, completed) do
    next =
      run.steps
      |> Enum.filter(fn {_id, s} -> s.status == :pending end)
      |> Enum.filter(fn {step_id, _s} ->
        not MapSet.member?(completed, step_id) and
          run.edges
          |> Enum.filter(fn e -> e.target == step_id end)
          |> Enum.all?(fn e -> MapSet.member?(completed, e.source) end)
      end)
      |> Enum.map(fn {id, _s} -> id end)

    case next do
      [] ->
        Enum.reverse(acc)

      step_ids ->
        wave = %{wave: length(acc) + 1, steps: step_ids}
        new_completed = Enum.reduce(step_ids, completed, &MapSet.put(&2, &1))
        do_compute_order(run, [wave | acc], new_completed)
    end
  end

  defp maybe_complete_run(run) do
    all_done =
      Enum.all?(run.steps, fn {_id, s} ->
        s.status in [:completed, :skipped, :failed]
      end)

    if all_done do
      has_failures = Enum.any?(run.steps, fn {_id, s} -> s.status == :failed end)
      new_status = if has_failures, do: :failed, else: :completed
      broadcast(:run_completed, %{run_id: run.id, status: new_status})
      %{run | status: new_status}
    else
      %{run | status: :running}
    end
  end

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(ApmV5.PubSub, @pubsub_topic, {event, payload})
  rescue
    _ -> :ok
  end
end
