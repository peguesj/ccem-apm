defmodule Apm.Orchestration.OrchestrationRunStore do
  @moduledoc """
  LRU run history store for orchestration runs.

  Stores up to `@max_runs` runs in an ETS table, evicting the oldest
  entry when the limit is exceeded. Supports retrieval by id and
  filtering by `orchestration_type`.
  """

  use GenServer
  require Logger

  @table :orchestration_run_store
  @max_runs 100

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Store or update a run."
  @spec put(map()) :: :ok
  def put(run) do
    GenServer.call(__MODULE__, {:put, run})
  end

  @doc "Get a single run by id."
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(id) do
    case :ets.lookup(@table, id) do
      [{^id, run}] -> {:ok, run}
      [] -> {:error, :not_found}
    end
  end

  @doc "List all runs."
  @spec list() :: [map()]
  def list do
    :ets.tab2list(@table)
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
  end

  @doc "List runs filtered by orchestration_type."
  @spec list_by_type(atom()) :: [map()]
  def list_by_type(type) when is_atom(type) do
    :ets.tab2list(@table)
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(&1.orchestration_type == type))
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
  end

  @doc "Delete a run by id."
  @spec delete(String.t()) :: :ok
  def delete(id) do
    :ets.delete(@table, id)
    :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{order: []}}
  end

  @impl true
  def handle_call({:put, run}, _from, %{order: order} = state) do
    id = run.id
    :ets.insert(@table, {id, run})

    new_order =
      if id in order do
        order
      else
        evict_if_needed([id | order])
      end

    {:reply, :ok, %{state | order: new_order}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp evict_if_needed(order) when length(order) <= @max_runs, do: order

  defp evict_if_needed(order) do
    {to_evict, remaining} = Enum.split(order, length(order) - @max_runs)
    Enum.each(to_evict, &:ets.delete(@table, &1))
    remaining
  end
end
