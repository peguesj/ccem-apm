defmodule ApmV4.BackfillStore do
  @moduledoc """
  GenServer that stores the last 50 UPM→Plane backfill run results.
  """
  use GenServer

  @max_runs 50

  # --- Client API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec get_state() :: map()
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @spec add_run(map()) :: :ok
  def add_run(run) do
    GenServer.cast(__MODULE__, {:add_run, run})
  end

  @spec set_rule_checked(boolean()) :: :ok
  def set_rule_checked(value) do
    GenServer.cast(__MODULE__, {:set_rule_checked, value})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    {:ok, %{runs: [], rule_checked: false, last_api_check: nil}}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:add_run, run}, state) do
    run_with_ts = Map.put_new(run, :started_at, DateTime.utc_now())
    runs = [run_with_ts | state.runs] |> Enum.take(@max_runs)
    {:noreply, %{state | runs: runs}}
  end

  @impl true
  def handle_cast({:set_rule_checked, value}, state) do
    {:noreply, %{state | rule_checked: value}}
  end
end
