defmodule ApmV4.UPM.ProjectRegistry do
  @moduledoc """
  GenServer that discovers, stores, and manages project records for all Claude Code
  projects detected via ProjectScanner. Uses ETS table :upm_projects with JSON
  persistence to ~/.ccem/upm/projects.json.
  """
  use GenServer
  require Logger

  @table :upm_projects
  @persist_path Path.expand("~/.ccem/upm/projects.json")
  @pubsub_topic "upm:projects"

  defmodule ProjectRecord do
    @moduledoc "Canonical project record for UPM tracking."
    @enforce_keys [:id, :name, :path]
    defstruct [
      :id,
      :name,
      :path,
      :stack,
      :plane_project_id,
      :linear_project_id,
      :vcs_url,
      :branch_strategy,
      :active_prd_branch,
      :last_seen_at,
      :tags
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            path: String.t(),
            stack: list(String.t()),
            plane_project_id: String.t() | nil,
            linear_project_id: String.t() | nil,
            vcs_url: String.t() | nil,
            branch_strategy: String.t() | nil,
            active_prd_branch: String.t() | nil,
            last_seen_at: DateTime.t() | nil,
            tags: list(String.t())
          }
  end

  # Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec list_projects() :: list(ProjectRecord.t())
  def list_projects do
    GenServer.call(__MODULE__, :list_projects)
  end

  @spec get_project(String.t()) :: {:ok, ProjectRecord.t()} | {:error, :not_found}
  def get_project(id) do
    GenServer.call(__MODULE__, {:get_project, id})
  end

  @spec upsert_project(map()) :: {:ok, ProjectRecord.t()}
  def upsert_project(attrs) do
    GenServer.call(__MODULE__, {:upsert_project, attrs})
  end

  @spec delete_project(String.t()) :: :ok | {:error, :not_found}
  def delete_project(id) do
    GenServer.call(__MODULE__, {:delete_project, id})
  end

  @spec scan_and_sync() :: {:ok, non_neg_integer()}
  def scan_and_sync do
    GenServer.call(__MODULE__, :scan_and_sync, 30_000)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    state = load_persisted_state()
    Enum.each(state, fn record ->
      :ets.insert(@table, {record.id, record})
    end)
    Logger.info("[UPM.ProjectRegistry] Initialized with #{length(state)} projects")
    {:ok, %{count: length(state)}}
  end

  @impl true
  def handle_call(:list_projects, _from, state) do
    projects =
      :ets.tab2list(@table)
      |> Enum.map(fn {_id, record} -> record end)
      |> Enum.sort_by(& &1.name)

    {:reply, projects, state}
  end

  @impl true
  def handle_call({:get_project, id}, _from, state) do
    result =
      case :ets.lookup(@table, id) do
        [{^id, record}] -> {:ok, record}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:upsert_project, attrs}, _from, state) do
    id = Map.get(attrs, :id) || Map.get(attrs, "id") || generate_id(attrs)

    record = %ProjectRecord{
      id: id,
      name: get_attr(attrs, :name, "unnamed"),
      path: get_attr(attrs, :path, ""),
      stack: get_attr(attrs, :stack, []),
      plane_project_id: get_attr(attrs, :plane_project_id),
      linear_project_id: get_attr(attrs, :linear_project_id),
      vcs_url: get_attr(attrs, :vcs_url),
      branch_strategy: get_attr(attrs, :branch_strategy),
      active_prd_branch: get_attr(attrs, :active_prd_branch),
      last_seen_at: DateTime.utc_now(),
      tags: get_attr(attrs, :tags, [])
    }

    :ets.insert(@table, {id, record})
    broadcast_update()
    {:reply, {:ok, record}, %{state | count: :ets.info(@table, :size)}}
  end

  @impl true
  def handle_call({:delete_project, id}, _from, state) do
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
  def handle_call(:scan_and_sync, _from, state) do
    count = do_scan_and_sync()
    {:reply, {:ok, count}, %{state | count: :ets.info(@table, :size)}}
  end

  @impl true
  def terminate(_reason, _state) do
    persist_state()
    :ok
  end

  # Private helpers

  defp do_scan_and_sync do
    try do
      scanned = ApmV4.ProjectScanner.scan()

      Enum.each(scanned, fn project_map ->
        attrs = %{
          id: project_map[:id] || project_map["id"] || generate_id(project_map),
          name: project_map[:name] || project_map["name"] || "unknown",
          path: project_map[:path] || project_map["path"] || "",
          stack: project_map[:stack] || project_map["stack"] || [],
          vcs_url: project_map[:vcs_url] || project_map["vcs_url"],
          active_prd_branch: project_map[:active_prd_branch] || project_map["active_prd_branch"],
          tags: project_map[:tags] || project_map["tags"] || []
        }

        id = attrs.id

        record = %ProjectRecord{
          id: id,
          name: attrs.name,
          path: attrs.path,
          stack: attrs.stack,
          plane_project_id: nil,
          linear_project_id: nil,
          vcs_url: attrs.vcs_url,
          branch_strategy: nil,
          active_prd_branch: attrs.active_prd_branch,
          last_seen_at: DateTime.utc_now(),
          tags: attrs.tags
        }

        :ets.insert(@table, {id, record})
      end)

      broadcast_update()
      length(scanned)
    rescue
      e ->
        Logger.warning("[UPM.ProjectRegistry] scan_and_sync failed: #{inspect(e)}")
        0
    end
  end

  defp load_persisted_state do
    path = @persist_path

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, list} <- Jason.decode(content, keys: :atoms) do
      Enum.map(list, &map_to_record/1)
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
      {:error, reason} -> Logger.error("[UPM.ProjectRegistry] Failed to persist: #{inspect(reason)}")
    end
  end

  defp broadcast_update do
    projects = :ets.tab2list(@table) |> Enum.map(fn {_id, r} -> r end)
    Phoenix.PubSub.broadcast(ApmV4.PubSub, @pubsub_topic, {:upm_projects_updated, projects})
  end

  defp generate_id(attrs) do
    name = get_attr(attrs, :name, "") || get_attr(attrs, "name", "")
    path = get_attr(attrs, :path, "") || get_attr(attrs, "path", "")
    :crypto.hash(:sha256, "#{name}:#{path}") |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp get_attr(map, key, default \\ nil) do
    Map.get(map, key) || Map.get(map, to_string(key)) || default
  end

  defp map_to_record(map) do
    %ProjectRecord{
      id: to_string(map[:id] || ""),
      name: to_string(map[:name] || ""),
      path: to_string(map[:path] || ""),
      stack: list_of_strings(map[:stack]),
      plane_project_id: nilify(map[:plane_project_id]),
      linear_project_id: nilify(map[:linear_project_id]),
      vcs_url: nilify(map[:vcs_url]),
      branch_strategy: nilify(map[:branch_strategy]),
      active_prd_branch: nilify(map[:active_prd_branch]),
      last_seen_at: parse_dt(map[:last_seen_at]),
      tags: list_of_strings(map[:tags])
    }
  end

  defp record_to_map(record) do
    %{
      id: record.id,
      name: record.name,
      path: record.path,
      stack: record.stack || [],
      plane_project_id: record.plane_project_id,
      linear_project_id: record.linear_project_id,
      vcs_url: record.vcs_url,
      branch_strategy: record.branch_strategy,
      active_prd_branch: record.active_prd_branch,
      last_seen_at: record.last_seen_at && DateTime.to_iso8601(record.last_seen_at),
      tags: record.tags || []
    }
  end

  defp nilify(nil), do: nil
  defp nilify(""), do: nil
  defp nilify(v), do: to_string(v)

  defp list_of_strings(nil), do: []
  defp list_of_strings(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp list_of_strings(_), do: []

  defp parse_dt(nil), do: nil
  defp parse_dt(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
  defp parse_dt(_), do: nil
end
