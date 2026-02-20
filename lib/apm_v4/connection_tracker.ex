defmodule ApmV4.ConnectionTracker do
  @moduledoc """
  ETS-backed GenServer tracking agent connections per project.

  Heartbeat staleness is detected via a periodic tick every 15s.
  Connections without a heartbeat for >60s are marked :stale.
  All state changes broadcast {:connection_updated, conn} on "apm:connections".
  """

  use GenServer

  @table :apm_connections
  @stale_ms 60_000
  @tick_ms 15_000

  # --- Client API ---

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @spec register(String.t(), String.t(), String.t()) :: :ok
  def register(session_id, project_name, agent_id) do
    GenServer.call(__MODULE__, {:register, session_id, project_name, agent_id})
  end

  @spec update_heartbeat(String.t()) :: :ok | {:error, :not_found}
  def update_heartbeat(session_id) do
    GenServer.call(__MODULE__, {:update_heartbeat, session_id})
  end

  @spec get_connections() :: [map()]
  def get_connections do
    :ets.tab2list(@table) |> Enum.map(fn {_id, c} -> c end)
  end

  @spec get_connections_by_project(String.t()) :: [map()]
  def get_connections_by_project(project_name) do
    get_connections() |> Enum.filter(&(&1.project_name == project_name))
  end

  @spec get_connections_grouped_by_project() :: %{String.t() => [map()]}
  def get_connections_grouped_by_project do
    get_connections() |> Enum.group_by(& &1.project_name)
  end

  @spec disconnect(String.t()) :: :ok
  def disconnect(session_id) do
    GenServer.call(__MODULE__, {:disconnect, session_id})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, session_id, project_name, agent_id}, _from, state) do
    conn = %{
      session_id: session_id,
      project_name: project_name,
      agent_id: agent_id,
      connected_at: DateTime.utc_now(),
      last_heartbeat: System.monotonic_time(:millisecond),
      status: :active
    }
    :ets.insert(@table, {session_id, conn})
    broadcast({:connection_updated, conn})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update_heartbeat, session_id}, _from, state) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, conn}] ->
        updated = %{conn | last_heartbeat: System.monotonic_time(:millisecond), status: :active}
        :ets.insert(@table, {session_id, updated})
        broadcast({:connection_updated, updated})
        {:reply, :ok, state}
      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:disconnect, session_id}, _from, state) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, conn}] ->
        updated = %{conn | status: :disconnected}
        :ets.insert(@table, {session_id, updated})
        broadcast({:connection_updated, updated})
      [] -> :ok
    end
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    now = System.monotonic_time(:millisecond)
    :ets.tab2list(@table)
    |> Enum.each(fn {id, conn} ->
      if conn.status == :active and now - conn.last_heartbeat > @stale_ms do
        updated = %{conn | status: :stale}
        :ets.insert(@table, {id, updated})
        broadcast({:connection_updated, updated})
      end
    end)
    schedule_tick()
    {:noreply, state}
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  defp broadcast(msg), do: Phoenix.PubSub.broadcast(ApmV4.PubSub, "apm:connections", msg)
end
