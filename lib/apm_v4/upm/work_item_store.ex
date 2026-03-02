defmodule ApmV4.UPM.WorkItemStore do
  @moduledoc """
  GenServer that caches work items from PM platforms in a canonical schema,
  supports drift detection between prd.json and platform state.
  ETS table :upm_work_items with JSON persistence to ~/.ccem/upm/work_items.json.
  """
  use GenServer
  require Logger

  @table :upm_work_items
  @persist_path Path.expand("~/.ccem/upm/work_items.json")
  @pubsub_topic "upm:work_items"

  @statuses [:backlog, :todo, :in_progress, :done, :cancelled]
  @priorities [:urgent, :high, :medium, :low, :none]
  @sync_statuses [:synced, :local_ahead, :platform_ahead, :conflict]

  defmodule WorkItem do
    @moduledoc "Canonical work item record for UPM cross-platform tracking."
    @enforce_keys [:id, :project_id]
    defstruct [
      :id,
      :project_id,
      :pm_integration_id,
      :title,
      :status,
      :priority,
      :platform_id,
      :platform_key,
      :platform_url,
      :prd_story_id,
      :passes,
      :branch_name,
      :pr_url,
      :commit_sha,
      :sync_status
    ]

    @type status :: :backlog | :todo | :in_progress | :done | :cancelled
    @type priority :: :urgent | :high | :medium | :low | :none
    @type sync_status :: :synced | :local_ahead | :platform_ahead | :conflict

    @type t :: %__MODULE__{
            id: String.t(),
            project_id: String.t(),
            pm_integration_id: String.t() | nil,
            title: String.t(),
            status: status(),
            priority: priority(),
            platform_id: String.t() | nil,
            platform_key: String.t() | nil,
            platform_url: String.t() | nil,
            prd_story_id: String.t() | nil,
            passes: boolean() | nil,
            branch_name: String.t() | nil,
            pr_url: String.t() | nil,
            commit_sha: String.t() | nil,
            sync_status: sync_status()
          }
  end

  # Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec list_items() :: list(WorkItem.t())
  def list_items do
    GenServer.call(__MODULE__, :list_items)
  end

  @spec list_for_project(String.t()) :: list(WorkItem.t())
  def list_for_project(project_id) do
    GenServer.call(__MODULE__, {:list_for_project, project_id})
  end

  @spec get_item(String.t()) :: {:ok, WorkItem.t()} | {:error, :not_found}
  def get_item(id) do
    GenServer.call(__MODULE__, {:get_item, id})
  end

  @spec upsert_item(map()) :: {:ok, WorkItem.t()} | {:error, term()}
  def upsert_item(attrs) do
    GenServer.call(__MODULE__, {:upsert_item, attrs})
  end

  @spec delete_item(String.t()) :: :ok | {:error, :not_found}
  def delete_item(id) do
    GenServer.call(__MODULE__, {:delete_item, id})
  end

  @spec detect_drift(String.t()) :: {:ok, :synced} | {:ok, {:drift, map()}} | {:error, term()}
  def detect_drift(id) do
    GenServer.call(__MODULE__, {:detect_drift, id})
  end

  @spec detect_drift_all() :: map()
  def detect_drift_all do
    GenServer.call(__MODULE__, :detect_drift_all, 30_000)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    state = load_persisted_state()
    Enum.each(state, fn record ->
      :ets.insert(@table, {record.id, record})
    end)
    Logger.info("[UPM.WorkItemStore] Initialized with #{length(state)} work items")
    {:ok, %{count: length(state)}}
  end

  @impl true
  def handle_call(:list_items, _from, state) do
    items =
      :ets.tab2list(@table)
      |> Enum.map(fn {_id, record} -> record end)
      |> Enum.sort_by(& &1.project_id)

    {:reply, items, state}
  end

  @impl true
  def handle_call({:list_for_project, project_id}, _from, state) do
    items =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_id, record} -> record.project_id == project_id end)
      |> Enum.map(fn {_id, record} -> record end)

    {:reply, items, state}
  end

  @impl true
  def handle_call({:get_item, id}, _from, state) do
    result =
      case :ets.lookup(@table, id) do
        [{^id, record}] -> {:ok, record}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:upsert_item, attrs}, _from, state) do
    with {:ok, record} <- build_record(attrs) do
      :ets.insert(@table, {record.id, record})
      broadcast_update()
      {:reply, {:ok, record}, %{state | count: :ets.info(@table, :size)}}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:delete_item, id}, _from, state) do
    result =
      case :ets.lookup(@table, id) do
        [{^id, _}] ->
          :ets.delete(@table, id)
          broadcast_update()
          :ok

        [] ->
          {:error, :not_found}
      end

    {:reply, result, %{state | count: :ets.info(@table, :size)}}
  end

  @impl true
  def handle_call({:detect_drift, id}, _from, state) do
    result =
      case :ets.lookup(@table, id) do
        [{^id, record}] -> do_detect_drift(record)
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:detect_drift_all, _from, state) do
    all_items = :ets.tab2list(@table) |> Enum.map(fn {_id, r} -> r end)

    summary =
      Enum.reduce(all_items, %{synced: 0, drifted: 0, errors: 0, details: []}, fn item, acc ->
        case do_detect_drift(item) do
          {:ok, :synced} ->
            %{acc | synced: acc.synced + 1}

          {:ok, {:drift, details}} ->
            %{
              acc
              | drifted: acc.drifted + 1,
                details: [%{id: item.id, title: item.title, drift: details} | acc.details]
            }

          _ ->
            %{acc | errors: acc.errors + 1}
        end
      end)

    {:reply, summary, state}
  end

  @impl true
  def terminate(_reason, _state) do
    persist_state()
    :ok
  end

  # Private helpers

  defp do_detect_drift(record) do
    # Compare local passes state vs platform status
    # local_ahead: passes=true but platform shows not done
    # platform_ahead: platform shows done but passes=false
    # synced: consistent
    # conflict: inconsistent combination

    local_done = record.passes == true
    platform_done = record.status == :done

    cond do
      local_done and platform_done ->
        {:ok, :synced}

      not local_done and not platform_done ->
        {:ok, :synced}

      local_done and not platform_done ->
        {:ok, {:drift, %{type: :local_ahead, local_passes: true, platform_status: record.status}}}

      not local_done and platform_done ->
        {:ok, {:drift, %{type: :platform_ahead, local_passes: false, platform_status: :done}}}

      true ->
        {:ok, {:drift, %{type: :conflict, local_passes: record.passes, platform_status: record.status}}}
    end
  end

  defp build_record(attrs) do
    id = get_attr(attrs, :id) || get_attr(attrs, "id") || generate_id(attrs)
    project_id = get_attr(attrs, :project_id) || get_attr(attrs, "project_id") || ""
    title = get_attr(attrs, :title) || get_attr(attrs, "title") || "Untitled"
    status = parse_status(get_attr(attrs, :status) || get_attr(attrs, "status"))
    priority = parse_priority(get_attr(attrs, :priority) || get_attr(attrs, "priority"))
    sync_status = parse_sync_status(get_attr(attrs, :sync_status) || get_attr(attrs, "sync_status"))

    record = %WorkItem{
      id: id,
      project_id: project_id,
      pm_integration_id: get_attr(attrs, :pm_integration_id) || get_attr(attrs, "pm_integration_id"),
      title: title,
      status: status,
      priority: priority,
      platform_id: get_attr(attrs, :platform_id) || get_attr(attrs, "platform_id"),
      platform_key: get_attr(attrs, :platform_key) || get_attr(attrs, "platform_key"),
      platform_url: get_attr(attrs, :platform_url) || get_attr(attrs, "platform_url"),
      prd_story_id: get_attr(attrs, :prd_story_id) || get_attr(attrs, "prd_story_id"),
      passes: get_attr(attrs, :passes) || get_attr(attrs, "passes"),
      branch_name: get_attr(attrs, :branch_name) || get_attr(attrs, "branch_name"),
      pr_url: get_attr(attrs, :pr_url) || get_attr(attrs, "pr_url"),
      commit_sha: get_attr(attrs, :commit_sha) || get_attr(attrs, "commit_sha"),
      sync_status: sync_status
    }

    {:ok, record}
  end

  defp parse_status(s) when s in @statuses, do: s
  defp parse_status("backlog"), do: :backlog
  defp parse_status("todo"), do: :todo
  defp parse_status("in_progress"), do: :in_progress
  defp parse_status("done"), do: :done
  defp parse_status("cancelled"), do: :cancelled
  defp parse_status(_), do: :backlog

  defp parse_priority(p) when p in @priorities, do: p
  defp parse_priority("urgent"), do: :urgent
  defp parse_priority("high"), do: :high
  defp parse_priority("medium"), do: :medium
  defp parse_priority("low"), do: :low
  defp parse_priority(_), do: :none

  defp parse_sync_status(s) when s in @sync_statuses, do: s
  defp parse_sync_status("synced"), do: :synced
  defp parse_sync_status("local_ahead"), do: :local_ahead
  defp parse_sync_status("platform_ahead"), do: :platform_ahead
  defp parse_sync_status("conflict"), do: :conflict
  defp parse_sync_status(_), do: :synced

  defp load_persisted_state do
    path = @persist_path

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, list} <- Jason.decode(content, keys: :atoms) do
      Enum.flat_map(list, fn map ->
        case build_record(map) do
          {:ok, record} -> [record]
          _ -> []
        end
      end)
    else
      _ -> []
    end
  end

  defp persist_state do
    path = @persist_path
    File.mkdir_p!(Path.dirname(path))

    records =
      :ets.tab2list(@table)
      |> Enum.map(fn {_id, record} -> record_to_map(record) end)

    case Jason.encode(records, pretty: true) do
      {:ok, json} -> File.write!(path, json)
      {:error, reason} -> Logger.error("[UPM.WorkItemStore] Persist failed: #{inspect(reason)}")
    end
  end

  defp broadcast_update do
    items = :ets.tab2list(@table) |> Enum.map(fn {_id, r} -> r end)
    Phoenix.PubSub.broadcast(ApmV4.PubSub, @pubsub_topic, {:upm_work_items_updated, items})
  end

  defp generate_id(attrs) do
    project_id = get_attr(attrs, :project_id) || get_attr(attrs, "project_id") || ""
    title = get_attr(attrs, :title) || get_attr(attrs, "title") || ""
    :crypto.hash(:sha256, "#{project_id}:#{title}") |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp get_attr(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp record_to_map(record) do
    %{
      id: record.id,
      project_id: record.project_id,
      pm_integration_id: record.pm_integration_id,
      title: record.title,
      status: record.status,
      priority: record.priority,
      platform_id: record.platform_id,
      platform_key: record.platform_key,
      platform_url: record.platform_url,
      prd_story_id: record.prd_story_id,
      passes: record.passes,
      branch_name: record.branch_name,
      pr_url: record.pr_url,
      commit_sha: record.commit_sha,
      sync_status: record.sync_status
    }
  end
end
