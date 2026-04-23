defmodule ApmV5.Orchestration.OrchestrationRunStore do
  @moduledoc """
  ETS-backed store for completed orchestration run history.

  Maintains a bounded history of completed runs (max 100, LRU eviction).
  Supports filtering, retrieval, and replay of historical runs.

  ## ETS Table

  - Name: `:orchestration_run_history`
  - Key: run_id (String.t)
  - Value: archived run map
  """

  use GenServer
  require Logger

  @table :orchestration_run_history
  @max_history 100

  # ── Public API ─────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Archive a completed run."
  @spec save_run(map()) :: :ok
  def save_run(run) when is_map(run) do
    GenServer.cast(__MODULE__, {:save_run, run})
  end

  @doc """
  List historical runs with optional filtering.

  ## Options

    * `:workflow_id` - filter by workflow ID
    * `:status` - filter by status atom
    * `:since` - filter runs created after this DateTime
    * `:limit` - max results (default 50)
  """
  @spec list_runs(keyword()) :: [map()]
  def list_runs(opts \\ []) do
    workflow_id = Keyword.get(opts, :workflow_id)
    status = Keyword.get(opts, :status)
    since = Keyword.get(opts, :since)
    limit = Keyword.get(opts, :limit, 50)

    :ets.tab2list(@table)
    |> Enum.map(fn {_id, run} -> run end)
    |> maybe_filter_workflow(workflow_id)
    |> maybe_filter_status(status)
    |> maybe_filter_since(since)
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc "Retrieve a historical run by ID."
  @spec get_run(String.t()) :: map() | nil
  def get_run(run_id) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, run}] -> run
      [] -> nil
    end
  end

  @doc """
  Create a new run from a historical run's config.
  Returns `{:ok, new_run}` or `{:error, reason}`.
  """
  @spec replay_run(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def replay_run(run_id, extra_params \\ %{}) do
    case get_run(run_id) do
      nil ->
        {:error, {:run_not_found, run_id}}

      historical_run ->
        params = Map.merge(historical_run.params || %{}, extra_params)
        ApmV5.Orchestration.OrchestrationManager.start_run(historical_run.workflow_id, params)
    end
  end

  @doc "Return the count of stored historical runs."
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table, :size)
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, read_concurrency: true])

    # Subscribe to orchestration events to auto-archive completed runs
    Phoenix.PubSub.subscribe(ApmV5.PubSub, ApmV5.Orchestration.OrchestrationManager.pubsub_topic())

    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:save_run, run}, state) do
    archived = Map.put(run, :archived_at, DateTime.utc_now())
    :ets.insert(@table, {run.id, archived})
    enforce_max_history()
    Logger.debug("[OrchestrationRunStore] Archived run #{run.id}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:run_completed, %{run_id: run_id}}, state) do
    case ApmV5.Orchestration.OrchestrationManager.get_run(run_id) do
      nil -> :ok
      run -> save_run(run)
    end

    {:noreply, state}
  end

  def handle_info({:run_cancelled, run}, state) do
    save_run(run)
    {:noreply, state}
  end

  # Ignore other PubSub messages
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ────────────────────────────────────────────────────────────────

  defp enforce_max_history do
    size = :ets.info(@table, :size)

    if size > @max_history do
      # Evict oldest entries
      all =
        :ets.tab2list(@table)
        |> Enum.map(fn {id, run} -> {id, run} end)
        |> Enum.sort_by(fn {_id, run} -> run.created_at end, {:asc, DateTime})

      to_remove = Enum.take(all, size - @max_history)
      Enum.each(to_remove, fn {id, _run} -> :ets.delete(@table, id) end)
    end
  end

  defp maybe_filter_workflow(runs, nil), do: runs
  defp maybe_filter_workflow(runs, wid), do: Enum.filter(runs, &(&1.workflow_id == wid))

  defp maybe_filter_status(runs, nil), do: runs
  defp maybe_filter_status(runs, status), do: Enum.filter(runs, &(&1.status == status))

  defp maybe_filter_since(runs, nil), do: runs

  defp maybe_filter_since(runs, since) do
    Enum.filter(runs, fn run ->
      DateTime.compare(run.created_at, since) in [:gt, :eq]
    end)
  end
end
