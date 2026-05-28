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
          id: String.t(),
          label: String.t(),
          type: :action | :gate | :decision | :terminal
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
    {:ok, %{}}
  end

  @impl true
  def handle_call({:start_run, params, _opts}, _from, state) do
    with :ok <- validate_type(params),
         run <- build_run(params) do
      :ets.insert(@table, {run.id, run})
      OrchestrationRunStore.put(run)
      broadcast_run_event(:run_started, run)
      {:reply, {:ok, run}, state}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:advance_step, run_id, step_id}, _from, state) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, run}] ->
        updated = %{run | current_step: step_id}
        :ets.insert(@table, {run_id, updated})
        OrchestrationRunStore.put(updated)
        broadcast_run_event(:run_advanced, updated)
        {:reply, {:ok, updated}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:cancel_run, run_id}, _from, state) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, run}] ->
        updated = %{run | status: :cancelled, completed_at: DateTime.utc_now()}
        :ets.insert(@table, {run_id, updated})
        OrchestrationRunStore.put(updated)
        broadcast_run_event(:run_cancelled, updated)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

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

  defp broadcast_run_event(event, run) do
    Phoenix.PubSub.broadcast(ApmV5.PubSub, "orchestration:runs", {event, run})
  end
end
