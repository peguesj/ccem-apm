defmodule ApmV4.UPM.SyncEngine do
  @moduledoc """
  GenServer that orchestrates bidirectional sync between PM platforms and WorkItemStore.
  Runs on a configurable schedule (default 5 minutes) and supports on-demand sync.
  """
  use GenServer
  require Logger

  @table :upm_sync_history
  @pubsub_topic "upm:sync"
  @max_history 50
  @sync_interval_ms 300_000

  defmodule SyncResult do
    @moduledoc "Result of a single sync operation."
    @enforce_keys [:project_id, :started_at]
    defstruct [
      :project_id,
      :synced_count,
      :drifted_count,
      :errors,
      :started_at,
      :completed_at
    ]

    @type t :: %__MODULE__{
            project_id: String.t(),
            synced_count: non_neg_integer(),
            drifted_count: non_neg_integer(),
            errors: list(String.t()),
            started_at: DateTime.t(),
            completed_at: DateTime.t() | nil
          }
  end

  # Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec sync_project(String.t()) :: {:ok, SyncResult.t()} | {:error, term()}
  def sync_project(project_id) do
    GenServer.call(__MODULE__, {:sync_project, project_id}, 60_000)
  end

  @spec get_history() :: list(SyncResult.t())
  def get_history do
    GenServer.call(__MODULE__, :get_history)
  end

  @spec get_history_for_project(String.t()) :: list(SyncResult.t())
  def get_history_for_project(project_id) do
    GenServer.call(__MODULE__, {:get_history_for_project, project_id})
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :ordered_set, :public, write_concurrency: true])
    :timer.send_interval(@sync_interval_ms, self(), :sync_all)
    Logger.info("[UPM.SyncEngine] Initialized, sync interval: #{@sync_interval_ms}ms")
    {:ok, %{running: false}}
  end

  @impl true
  def handle_info(:sync_all, %{running: true} = state) do
    Logger.debug("[UPM.SyncEngine] Skipping scheduled sync — previous sync still running")
    {:noreply, state}
  end

  @impl true
  def handle_info(:sync_all, state) do
    Logger.info("[UPM.SyncEngine] Starting scheduled sync for all projects")

    Task.start(fn ->
      projects = ApmV4.UPM.ProjectRegistry.list_projects()

      Enum.each(projects, fn project ->
        do_sync_project(project.id)
      end)

      Logger.info("[UPM.SyncEngine] Scheduled sync complete for #{length(projects)} projects")
    end)

    {:noreply, %{state | running: false}}
  end

  @impl true
  def handle_call({:sync_project, project_id}, _from, state) do
    result = do_sync_project(project_id)
    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    history =
      :ets.tab2list(@table)
      |> Enum.map(fn {_key, result} -> result end)
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
      |> Enum.take(@max_history)

    {:reply, history, state}
  end

  @impl true
  def handle_call({:get_history_for_project, project_id}, _from, state) do
    history =
      :ets.tab2list(@table)
      |> Enum.map(fn {_key, result} -> result end)
      |> Enum.filter(&(&1.project_id == project_id))
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})

    {:reply, history, state}
  end

  # Private

  defp do_sync_project(project_id) do
    started_at = DateTime.utc_now()
    integrations = ApmV4.UPM.PMIntegrationStore.list_for_project(project_id)

    {synced, drifted, errors} =
      Enum.reduce(integrations, {0, 0, []}, fn integration, {s, d, e} ->
        if integration.sync_enabled do
          case sync_integration(integration, project_id) do
            {:ok, {synced_count, drifted_count}} ->
              {s + synced_count, d + drifted_count, e}

            {:error, reason} ->
              {s, d, ["#{integration.platform}: #{reason}" | e]}
          end
        else
          {s, d, e}
        end
      end)

    result = %SyncResult{
      project_id: project_id,
      synced_count: synced,
      drifted_count: drifted,
      errors: errors,
      started_at: started_at,
      completed_at: DateTime.utc_now()
    }

    store_result(result)
    broadcast_result(result)
    result
  end

  defp sync_integration(integration, project_id) do
    adapter = ApmV4.UPM.Adapters.PMAdapter.get_adapter(integration.platform)

    if adapter == nil do
      {:error, "No adapter for #{integration.platform}"}
    else
      case apply(adapter, :list_issues, [integration]) do
        {:ok, issues} ->
          {synced, drifted} =
            Enum.reduce(issues, {0, 0}, fn issue, {s, d} ->
              normalized = apply(adapter, :normalize, [issue])

              attrs = Map.merge(normalized, %{
                project_id: project_id,
                pm_integration_id: integration.id,
                id: build_item_id(integration.id, normalized[:platform_id] || "")
              })

              case ApmV4.UPM.WorkItemStore.upsert_item(attrs) do
                {:ok, item} ->
                  case ApmV4.UPM.WorkItemStore.detect_drift(item.id) do
                    {:ok, :synced} -> {s + 1, d}
                    {:ok, {:drift, _}} -> {s + 1, d + 1}
                    _ -> {s + 1, d}
                  end

                _ ->
                  {s, d}
              end
            end)

          {:ok, {synced, drifted}}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  defp build_item_id(integration_id, platform_id) do
    :crypto.hash(:sha256, "#{integration_id}:#{platform_id}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp store_result(result) do
    key = {result.started_at, result.project_id}
    :ets.insert(@table, {key, result})

    # Trim to max history
    all = :ets.tab2list(@table)

    if length(all) > @max_history do
      oldest = all |> Enum.sort_by(fn {{dt, _}, _} -> dt end) |> List.first()
      if oldest, do: :ets.delete(@table, elem(oldest, 0))
    end
  end

  defp broadcast_result(result) do
    Phoenix.PubSub.broadcast(ApmV4.PubSub, @pubsub_topic, {:upm_sync_complete, result})
  end
end
