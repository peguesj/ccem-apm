defmodule ApmV4.UPM.PMIntegrationStore do
  @moduledoc """
  GenServer that stores PM platform integration configs (Plane, Linear, Jira, Monday,
  MSProject) per project. ETS table :upm_pm_integrations with JSON persistence to
  ~/.ccem/upm/pm_integrations.json.
  """
  use GenServer
  require Logger

  @table :upm_pm_integrations
  @persist_path Path.expand("~/.ccem/upm/pm_integrations.json")
  @pubsub_topic "upm:pm_integrations"

  @platforms [:plane, :linear, :jira, :monday, :ms_project]

  defmodule PMIntegration do
    @moduledoc "PM platform integration configuration record."
    @enforce_keys [:id, :project_id, :platform]
    defstruct [
      :id,
      :project_id,
      :platform,
      :base_url,
      :api_key,
      :workspace,
      :project_key,
      :sync_enabled,
      :last_sync_at
    ]

    @type platform :: :plane | :linear | :jira | :monday | :ms_project

    @type t :: %__MODULE__{
            id: String.t(),
            project_id: String.t(),
            platform: platform(),
            base_url: String.t() | nil,
            api_key: String.t() | nil,
            workspace: String.t() | nil,
            project_key: String.t() | nil,
            sync_enabled: boolean(),
            last_sync_at: DateTime.t() | nil
          }
  end

  # Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec list_integrations() :: list(PMIntegration.t())
  def list_integrations do
    GenServer.call(__MODULE__, :list_integrations)
  end

  @spec list_for_project(String.t()) :: list(PMIntegration.t())
  def list_for_project(project_id) do
    GenServer.call(__MODULE__, {:list_for_project, project_id})
  end

  @spec get_integration(String.t()) :: {:ok, PMIntegration.t()} | {:error, :not_found}
  def get_integration(id) do
    GenServer.call(__MODULE__, {:get_integration, id})
  end

  @spec upsert_integration(map()) :: {:ok, PMIntegration.t()} | {:error, term()}
  def upsert_integration(attrs) do
    GenServer.call(__MODULE__, {:upsert_integration, attrs})
  end

  @spec delete_integration(String.t()) :: :ok | {:error, :not_found}
  def delete_integration(id) do
    GenServer.call(__MODULE__, {:delete_integration, id})
  end

  @spec test_connection(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def test_connection(id) do
    GenServer.call(__MODULE__, {:test_connection, id}, 15_000)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    state = load_persisted_state()
    Enum.each(state, fn record ->
      :ets.insert(@table, {record.id, record})
    end)
    Logger.info("[UPM.PMIntegrationStore] Initialized with #{length(state)} integrations")
    {:ok, %{count: length(state)}}
  end

  @impl true
  def handle_call(:list_integrations, _from, state) do
    integrations =
      :ets.tab2list(@table)
      |> Enum.map(fn {_id, record} -> record end)
      |> Enum.sort_by(& &1.project_id)

    {:reply, integrations, state}
  end

  @impl true
  def handle_call({:list_for_project, project_id}, _from, state) do
    integrations =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_id, record} -> record.project_id == project_id end)
      |> Enum.map(fn {_id, record} -> record end)

    {:reply, integrations, state}
  end

  @impl true
  def handle_call({:get_integration, id}, _from, state) do
    result =
      case :ets.lookup(@table, id) do
        [{^id, record}] -> {:ok, record}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:upsert_integration, attrs}, _from, state) do
    with {:ok, record} <- build_record(attrs) do
      :ets.insert(@table, {record.id, record})
      broadcast_update()
      {:reply, {:ok, record}, %{state | count: :ets.info(@table, :size)}}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:delete_integration, id}, _from, state) do
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
  def handle_call({:test_connection, id}, _from, state) do
    result =
      case :ets.lookup(@table, id) do
        [{^id, record}] ->
          adapter_module = adapter_for(record.platform)
          apply(adapter_module, :test_connection, [record])

        [] ->
          {:error, "Integration not found"}
      end

    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, _state) do
    persist_state()
    :ok
  end

  # Private helpers

  defp build_record(attrs) do
    platform = parse_platform(get_attr(attrs, :platform) || get_attr(attrs, "platform"))

    if platform == nil do
      {:error, :invalid_platform}
    else
      id = get_attr(attrs, :id) || get_attr(attrs, "id") || generate_id(attrs)
      project_id = get_attr(attrs, :project_id) || get_attr(attrs, "project_id") || ""

      record = %PMIntegration{
        id: id,
        project_id: project_id,
        platform: platform,
        base_url: get_attr(attrs, :base_url) || get_attr(attrs, "base_url"),
        api_key: get_attr(attrs, :api_key) || get_attr(attrs, "api_key"),
        workspace: get_attr(attrs, :workspace) || get_attr(attrs, "workspace"),
        project_key: get_attr(attrs, :project_key) || get_attr(attrs, "project_key"),
        sync_enabled: get_attr(attrs, :sync_enabled) || get_attr(attrs, "sync_enabled") || false,
        last_sync_at: nil
      }

      {:ok, record}
    end
  end

  defp parse_platform(p) when p in @platforms, do: p
  defp parse_platform(p) when is_binary(p) do
    case p do
      "plane" -> :plane
      "linear" -> :linear
      "jira" -> :jira
      "monday" -> :monday
      "ms_project" -> :ms_project
      _ -> nil
    end
  end
  defp parse_platform(_), do: nil

  defp adapter_for(:plane), do: ApmV4.UPM.Adapters.PlaneAdapter
  defp adapter_for(:linear), do: ApmV4.UPM.Adapters.LinearAdapter
  defp adapter_for(:jira), do: ApmV4.UPM.Adapters.JiraAdapter
  defp adapter_for(:monday), do: ApmV4.UPM.Adapters.MondayAdapter
  defp adapter_for(:ms_project), do: ApmV4.UPM.Adapters.MSProjectAdapter

  defp load_persisted_state do
    path = @persist_path

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, list} <- Jason.decode(content, keys: :atoms) do
      Enum.flat_map(list, fn map ->
        case build_record(map) do
          {:ok, record} ->
            last_sync = parse_dt(map[:last_sync_at])
            [%{record | last_sync_at: last_sync}]
          _ ->
            []
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
      {:error, reason} -> Logger.error("[UPM.PMIntegrationStore] Persist failed: #{inspect(reason)}")
    end
  end

  defp broadcast_update do
    integrations = :ets.tab2list(@table) |> Enum.map(fn {_id, r} -> r end)

    Phoenix.PubSub.broadcast(
      ApmV4.PubSub,
      @pubsub_topic,
      {:upm_pm_integrations_updated, integrations}
    )
  end

  defp generate_id(attrs) do
    project_id = get_attr(attrs, :project_id) || get_attr(attrs, "project_id") || ""
    platform = get_attr(attrs, :platform) || get_attr(attrs, "platform") || ""
    :crypto.hash(:sha256, "#{project_id}:#{platform}") |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp get_attr(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp record_to_map(record) do
    %{
      id: record.id,
      project_id: record.project_id,
      platform: record.platform,
      base_url: record.base_url,
      api_key: record.api_key,
      workspace: record.workspace,
      project_key: record.project_key,
      sync_enabled: record.sync_enabled,
      last_sync_at: record.last_sync_at && DateTime.to_iso8601(record.last_sync_at)
    }
  end

  defp parse_dt(nil), do: nil
  defp parse_dt(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
  defp parse_dt(_), do: nil
end
