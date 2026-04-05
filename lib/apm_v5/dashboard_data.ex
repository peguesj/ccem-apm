defmodule ApmV5.DashboardData do
  @moduledoc """
  Dedicated snapshot cache for DashboardLive mount data (US-603).

  DashboardLive.mount/3 historically issued multiple sequential GenServer.calls
  (PortManager × 3, ProjectStore × 2, UpmStore, DashboardStore × 2, etc.). On
  cold-path mounts this serialized 7–12 calls before the socket could connect.

  This GenServer maintains a preloaded `%Snapshot{}` refreshed every 2s so
  each mount only performs a single ETS lookup via `snapshot/0`.

  Project-scoped data (agents, tasks, commands, ralph_data) is NOT cached here
  because the active_project is per-connection — those stay lazy per-mount.
  Only the heavy, cross-project GenServer calls are precomputed.
  """

  use GenServer
  require Logger

  @table :apm_dashboard_snapshot
  @refresh_ms 2_000

  defmodule Snapshot do
    @moduledoc false
    defstruct [
      :project_configs,
      :port_clashes,
      :port_ranges,
      :saved_layouts,
      :saved_presets,
      :upm_status,
      :built_at_ms
    ]

    @type t :: %__MODULE__{
            project_configs: map(),
            port_clashes: list(),
            port_ranges: map(),
            saved_layouts: list(),
            saved_presets: list(),
            upm_status: map() | nil,
            built_at_ms: integer()
          }
  end

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the most recent dashboard snapshot. Single ETS lookup, no GenServer call.
  Returns an empty snapshot if cache hasn't been warmed yet (first 2s after boot).
  """
  @spec snapshot() :: Snapshot.t()
  def snapshot do
    case :ets.lookup(@table, :current) do
      [{:current, %Snapshot{} = s}] -> s
      _ -> empty_snapshot()
    end
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    # Seed with empty snapshot so reads before first build don't crash
    :ets.insert(@table, {:current, empty_snapshot()})
    {:ok, %{}, {:continue, :warmup}}
  end

  @impl true
  def handle_continue(:warmup, state) do
    build_and_store_async()
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    build_and_store_async()
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:store, %Snapshot{} = snap}, state) do
    :ets.insert(@table, {:current, snap})
    {:noreply, state}
  end

  # --- Private ---

  defp build_and_store_async do
    server = self()

    Task.start(fn ->
      snap = build_snapshot()
      GenServer.cast(server, {:store, snap})
    end)
  end

  defp build_snapshot do
    %Snapshot{
      project_configs: safe(fn -> ApmV5.PortManager.get_project_configs() end, %{}),
      port_clashes: safe(fn -> ApmV5.PortManager.detect_clashes() end, []),
      port_ranges: safe(fn -> ApmV5.PortManager.get_port_ranges() end, %{}),
      saved_layouts: safe(fn -> ApmV5.DashboardStore.list_layouts() end, []),
      saved_presets: safe(fn -> ApmV5.DashboardStore.list_presets() end, []),
      upm_status: safe(fn -> ApmV5.UpmStore.get_status() end, nil),
      built_at_ms: System.monotonic_time(:millisecond)
    }
  end

  defp empty_snapshot do
    %Snapshot{
      project_configs: %{},
      port_clashes: [],
      port_ranges: %{},
      saved_layouts: [],
      saved_presets: [],
      upm_status: nil,
      built_at_ms: 0
    }
  end

  defp safe(fun, default) do
    try do
      fun.()
    rescue
      _ -> default
    catch
      :exit, _ -> default
    end
  end
end
