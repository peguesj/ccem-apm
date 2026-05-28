defmodule ApmV5.Orchestration.OrchestrationManager do
  @moduledoc """
  GenServer managing the DAG-based orchestration engine.

  Handles run lifecycle: start, advance, complete, cancel. Validates
  type-specific constraints and broadcasts run events via PubSub.

  ## Orchestration types
  - `:pipeline`    — linear sequence, no cycles allowed
  - `:workflow`    — DAG with conditional branches (default)
  - `:maintenance` — scheduled/recurring; requires `schedule` param
  - `:sync`        — bidirectional reconciliation; requires `source` and `target`
  - `:formation`   — multi-wave agent deployment
  - `:autonomous`  — self-directing decision loops (Ralph pattern)

  ## ETS table
  - `:orchestration_runs` — keyed by run id
  """

  use GenServer
  require Logger

  alias ApmV5.Orchestration.OrchestrationRunStore

  @type orchestration_type :: :pipeline | :workflow | :maintenance | :sync | :formation | :autonomous

  @type step :: %{
          required(:id) => String.t(),
          required(:label) => String.t(),
          required(:type) => :action | :gate | :decision | :terminal | :approval,
          optional(:timeout_ms) => pos_integer() | nil
        }

  @type edge :: %{source: String.t(), target: String.t()}

  @type run :: %{
          id: String.t(),
          orchestration_type: orchestration_type(),
          status: :pending | :running | :completed | :failed | :cancelled,
          steps: [step()],
          edges: [edge()],
          current_step: String.t() | nil,
          metadata: map(),
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil
        }

  @table :orchestration_runs

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start a new orchestration run from a params map.

  Required keys: `:steps`, `:edges`.
  Optional keys: `:orchestration_type` (default `:workflow`), `:schedule`,
                 `:source`, `:target`, and any metadata.

  Returns `{:ok, run}` or `{:error, reason}`.
  """
  @spec start_run(map(), keyword()) :: {:ok, run()} | {:error, term()}
  def start_run(params, opts \\ []) do
    GenServer.call(__MODULE__, {:start_run, params, opts})
  end

  @doc "Advance a run to the next step."
  @spec advance_step(String.t(), String.t()) :: {:ok, run()} | {:error, term()}
  def advance_step(run_id, step_id) do
    GenServer.call(__MODULE__, {:advance_step, run_id, step_id})
  end

  @doc "Cancel a running orchestration."
  @spec cancel_run(String.t()) :: :ok | {:error, :not_found}
  def cancel_run(run_id) do
    GenServer.call(__MODULE__, {:cancel_run, run_id})
  end

  @doc """
  Return a deterministic topological ordering of step IDs for the given edges.

  Uses `:digraph_utils.topsort/1` so that parallel steps can be dispatched in
  dependency order without relying on list insertion order.

  Returns `{:ok, [step_id]}` or `{:error, :cycle}` if the graph has cycles.
  """
  @spec step_order([edge()]) :: {:ok, [String.t()]} | {:error, :cycle}
  def step_order(edges) do
    topo_sort(edges)
  end

  @doc """
  Grant approval for an `:approval`-type step, advancing the run.

  When a run is paused at an `:approval` step, it will not advance
  automatically.  Call this function with optional `approver_info` to
  unblock the run and transition it to the next step (via `advance_step/2`).

  Emits `{:run_step_approved, run_id, step_id}` on `"apm:orchestration"`.

  Returns `{:ok, run}` or `{:error, reason}`.
  """
  @spec grant_approval(String.t(), String.t(), map()) :: {:ok, run()} | {:error, term()}
  def grant_approval(run_id, step_id, approver_info \\ %{}) do
    GenServer.call(__MODULE__, {:grant_approval, run_id, step_id, approver_info})
  end

  @doc "Get a run by id."
  @spec get_run(String.t()) :: {:ok, run()} | {:error, :not_found}
  def get_run(run_id) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, run}] -> {:ok, run}
      [] -> {:error, :not_found}
    end
  end

  @doc "List all active (non-terminal) runs."
  @spec list_runs() :: [run()]
  def list_runs do
    :ets.tab2list(@table) |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Map a run's metadata to OpenTelemetry gen_ai semantic convention attribute names.

  Returns a flat string-keyed map aligned with the `gen_ai.*` attribute namespace.
  """
  @spec otel_attributes(run()) :: %{String.t() => String.t()}
  def otel_attributes(%{id: id, orchestration_type: type} = _run) do
    %{
      "gen_ai.operation.name" => Atom.to_string(type),
      "gen_ai.system" => "ccem_apm",
      "gen_ai.request.id" => id
    }
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    # timers: %{"{run_id}:{step_id}" => timer_ref}
    {:ok, %{timers: %{}}}
  end

  @impl true
  def handle_call({:start_run, params, _opts}, _from, state) do
    with :ok <- validate_type(params),
         run <- build_run(params) do
      :ets.insert(@table, {run.id, run})
      OrchestrationRunStore.put(run)
      broadcast_run_event(:run_started, run)

      # Schedule timeouts for any steps that carry a timeout_ms field
      new_timers =
        Enum.reduce(run.steps, state.timers, fn step, acc ->
          case Map.get(step, :timeout_ms) do
            nil ->
              acc

            ms when is_integer(ms) and ms > 0 ->
              timer_key = "#{run.id}:#{step.id}"
              ref = Process.send_after(self(), {:step_timeout, run.id, step.id}, ms)
              Map.put(acc, timer_key, ref)

            _ ->
              acc
          end
        end)

      {:reply, {:ok, run}, %{state | timers: new_timers}}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:advance_step, run_id, step_id}, _from, state) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, run}] ->
        # Cancel any pending timeout for the step being advanced away from
        timer_key = "#{run_id}:#{Map.get(run, :current_step, step_id)}"
        new_timers = cancel_timer_if_present(state.timers, timer_key)

        updated = %{run | current_step: step_id}
        :ets.insert(@table, {run_id, updated})
        OrchestrationRunStore.put(updated)
        broadcast_run_event(:run_advanced, updated)
        {:reply, {:ok, updated}, %{state | timers: new_timers}}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:cancel_run, run_id}, _from, state) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, run}] ->
        # Cancel all timers for this run
        new_timers =
          Enum.reduce(run.steps, state.timers, fn step, acc ->
            cancel_timer_if_present(acc, "#{run_id}:#{step.id}")
          end)

        updated = %{run | status: :cancelled, completed_at: DateTime.utc_now()}
        :ets.insert(@table, {run_id, updated})
        OrchestrationRunStore.put(updated)
        broadcast_run_event(:run_cancelled, updated)
        {:reply, :ok, %{state | timers: new_timers}}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:grant_approval, run_id, step_id, approver_info}, _from, state) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, run}] ->
        # Verify current step is an :approval type
        current_step = Enum.find(run.steps, &(&1.id == step_id))

        cond do
          is_nil(current_step) ->
            {:reply, {:error, :step_not_found}, state}

          Map.get(current_step, :type) != :approval ->
            {:reply, {:error, :not_an_approval_step}, state}

          true ->
            # Cancel any pending timeout for this step before approving
            timer_key = "#{run_id}:#{step_id}"
            new_timers = cancel_timer_if_present(state.timers, timer_key)

            # Broadcast approval event before advancing
            Phoenix.PubSub.broadcast(
              ApmV5.PubSub,
              "apm:orchestration",
              {:run_step_approved, run_id, step_id, approver_info}
            )

            # Advance to the next step in topo order
            next_step_id = next_step_after(run, step_id)

            updated =
              run
              |> Map.put(:current_step, next_step_id)
              |> Map.put(:metadata, Map.put(run.metadata, :last_approval, %{
                  step_id: step_id,
                  approver_info: approver_info,
                  approved_at: DateTime.utc_now()
                }))

            :ets.insert(@table, {run_id, updated})
            OrchestrationRunStore.put(updated)
            broadcast_run_event(:run_advanced, updated)
            {:reply, {:ok, updated}, %{state | timers: new_timers}}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # ---------------------------------------------------------------------------
  # handle_info: step timeout
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:step_timeout, run_id, step_id}, state) do
    timer_key = "#{run_id}:#{step_id}"
    new_timers = Map.delete(state.timers, timer_key)

    case :ets.lookup(@table, run_id) do
      [{^run_id, run}] ->
        # Only fail the run if the step is still the current/active step
        # (or if current_step is nil, meaning we haven't advanced past it)
        active_step = run.current_step

        if is_nil(active_step) or active_step == step_id do
          Logger.warning(
            "[OrchestrationManager] Step timeout: run=#{run_id} step=#{step_id}"
          )

          updated = %{run | status: :failed, completed_at: DateTime.utc_now(),
                      metadata: Map.put(run.metadata, :failure_reason, {:timeout, step_id})}
          :ets.insert(@table, {run_id, updated})
          OrchestrationRunStore.put(updated)
          broadcast_run_event(:run_failed, updated)

          Phoenix.PubSub.broadcast(
            ApmV5.PubSub,
            "apm:orchestration",
            {:run_step_timeout, run_id, step_id}
          )
        end

      [] ->
        :ok
    end

    {:noreply, %{state | timers: new_timers}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp cancel_timer_if_present(timers, key) do
    case Map.pop(timers, key) do
      {nil, timers} ->
        timers

      {ref, timers} ->
        Process.cancel_timer(ref)
        timers
    end
  end

  defp validate_type(%{orchestration_type: :pipeline} = params) do
    case detect_cycle(Map.get(params, :edges, [])) do
      true -> {:error, {:cycle_detected, "pipeline type does not permit cycles"}}
      false -> :ok
    end
  end

  defp validate_type(%{orchestration_type: :maintenance} = params) do
    case Map.get(params, :schedule) do
      nil -> {:error, {:missing_required_param, :schedule}}
      _ -> :ok
    end
  end

  defp validate_type(%{orchestration_type: :sync} = params) do
    cond do
      is_nil(Map.get(params, :source)) -> {:error, {:missing_required_param, :source}}
      is_nil(Map.get(params, :target)) -> {:error, {:missing_required_param, :target}}
      true -> :ok
    end
  end

  defp validate_type(_params), do: :ok

  # Detect cycles using OTP's built-in :digraph_utils.is_acyclic/1.
  #
  # Replaces 34-LOC custom DFS (detect_cycle/1 + has_cycle_from?/4) with a
  # single stdlib call. :digraph/:digraph_utils are part of the Erlang stdlib
  # (stdlib application) — no additional dependency required.
  #
  # The :digraph is created, used, and deleted within a try/after block to
  # guarantee the ETS tables backing the digraph are always cleaned up.
  @spec detect_cycle([edge()]) :: boolean()
  defp detect_cycle(edges) do
    dg = :digraph.new()

    try do
      # Collect all unique vertex IDs from both source and target sides
      vertex_ids =
        edges
        |> Enum.flat_map(fn %{source: s, target: t} -> [s, t] end)
        |> Enum.uniq()

      Enum.each(vertex_ids, &:digraph.add_vertex(dg, &1))

      Enum.each(edges, fn %{source: s, target: t} ->
        :digraph.add_edge(dg, s, t)
      end)

      not :digraph_utils.is_acyclic(dg)
    after
      :digraph.delete(dg)
    end
  end

  # Return a topologically sorted list of step IDs for deterministic scheduling.
  #
  # Uses :digraph_utils.topsort/1 which returns vertices in topological order
  # (dependencies before dependents) or `false` if the graph has cycles.
  # Returns {:ok, [step_id]} or {:error, :cycle} to mirror detect_cycle semantics.
  @spec topo_sort([edge()]) :: {:ok, [String.t()]} | {:error, :cycle}
  defp topo_sort(edges) do
    dg = :digraph.new()

    try do
      vertex_ids =
        edges
        |> Enum.flat_map(fn %{source: s, target: t} -> [s, t] end)
        |> Enum.uniq()

      Enum.each(vertex_ids, &:digraph.add_vertex(dg, &1))

      Enum.each(edges, fn %{source: s, target: t} ->
        :digraph.add_edge(dg, s, t)
      end)

      case :digraph_utils.topsort(dg) do
        false -> {:error, :cycle}
        order -> {:ok, order}
      end
    after
      :digraph.delete(dg)
    end
  end

  defp build_run(params) do
    type = Map.get(params, :orchestration_type, :workflow)
    metadata = build_metadata(params)

    %{
      id: generate_id(),
      orchestration_type: type,
      status: :running,
      steps: Map.get(params, :steps, []),
      edges: Map.get(params, :edges, []),
      current_step: nil,
      metadata: metadata,
      started_at: DateTime.utc_now(),
      completed_at: nil
    }
  end

  defp build_metadata(params) do
    base = Map.get(params, :metadata, %{})

    base
    |> maybe_put(:schedule, Map.get(params, :schedule))
    |> maybe_put(:source, Map.get(params, :source))
    |> maybe_put(:target, Map.get(params, :target))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # Determine the next step ID after the given step_id using topo order.
  # Returns nil if the step is the last in the DAG.
  defp next_step_after(run, step_id) do
    case topo_sort(run.edges) do
      {:ok, order} ->
        idx = Enum.find_index(order, &(&1 == step_id))

        if is_nil(idx) do
          nil
        else
          Enum.at(order, idx + 1)
        end

      {:error, :cycle} ->
        nil
    end
  end

  defp broadcast_run_event(event, run) do
    Phoenix.PubSub.broadcast(ApmV5.PubSub, "orchestration:runs", {event, run})
    Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:orchestration", {event, run})
  end
end
