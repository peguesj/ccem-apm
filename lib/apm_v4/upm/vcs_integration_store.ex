defmodule ApmV4.UPM.VCSIntegrationStore do
  @moduledoc """
  GenServer that stores VCS integration configs (GitHub, AzureDevOps) per project
  with branch strategy mapping. ETS table :upm_vcs_integrations with JSON persistence
  to ~/.ccem/upm/vcs_integrations.json.
  """
  use GenServer
  require Logger

  @table :upm_vcs_integrations
  @persist_path Path.expand("~/.ccem/upm/vcs_integrations.json")
  @pubsub_topic "upm:vcs_integrations"

  @providers [:github, :azure_devops]
  @sync_types [:bidirectional, :push, :pull]

  defmodule VCSIntegration do
    @moduledoc "VCS integration configuration record."
    @enforce_keys [:id, :project_id, :provider]
    defstruct [
      :id,
      :project_id,
      :provider,
      :repo_url,
      :default_branch,
      :qa_branch,
      :staging_branch,
      :prod_branch,
      :sync_type,
      :resource_group,
      :last_sync_at
    ]

    @type provider :: :github | :azure_devops
    @type sync_type :: :bidirectional | :push | :pull

    @type t :: %__MODULE__{
            id: String.t(),
            project_id: String.t(),
            provider: provider(),
            repo_url: String.t() | nil,
            default_branch: String.t() | nil,
            qa_branch: String.t() | nil,
            staging_branch: String.t() | nil,
            prod_branch: String.t() | nil,
            sync_type: sync_type() | nil,
            resource_group: String.t() | nil,
            last_sync_at: DateTime.t() | nil
          }
  end

  # Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec list_integrations() :: list(VCSIntegration.t())
  def list_integrations do
    GenServer.call(__MODULE__, :list_integrations)
  end

  @spec list_for_project(String.t()) :: list(VCSIntegration.t())
  def list_for_project(project_id) do
    GenServer.call(__MODULE__, {:list_for_project, project_id})
  end

  @spec get_integration(String.t()) :: {:ok, VCSIntegration.t()} | {:error, :not_found}
  def get_integration(id) do
    GenServer.call(__MODULE__, {:get_integration, id})
  end

  @spec upsert_integration(map()) :: {:ok, VCSIntegration.t()} | {:error, term()}
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
    Logger.info("[UPM.VCSIntegrationStore] Initialized with #{length(state)} integrations")
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
          adapter_module = adapter_for(record.provider)
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
    provider = parse_provider(get_attr(attrs, :provider) || get_attr(attrs, "provider"))

    if provider == nil do
      {:error, :invalid_provider}
    else
      id = get_attr(attrs, :id) || get_attr(attrs, "id") || generate_id(attrs)
      project_id = get_attr(attrs, :project_id) || get_attr(attrs, "project_id") || ""
      sync_type = parse_sync_type(get_attr(attrs, :sync_type) || get_attr(attrs, "sync_type"))

      record = %VCSIntegration{
        id: id,
        project_id: project_id,
        provider: provider,
        repo_url: get_attr(attrs, :repo_url) || get_attr(attrs, "repo_url"),
        default_branch: get_attr(attrs, :default_branch) || get_attr(attrs, "default_branch") || "main",
        qa_branch: get_attr(attrs, :qa_branch) || get_attr(attrs, "qa_branch"),
        staging_branch: get_attr(attrs, :staging_branch) || get_attr(attrs, "staging_branch"),
        prod_branch: get_attr(attrs, :prod_branch) || get_attr(attrs, "prod_branch"),
        sync_type: sync_type,
        resource_group: get_attr(attrs, :resource_group) || get_attr(attrs, "resource_group"),
        last_sync_at: nil
      }

      {:ok, record}
    end
  end

  defp parse_provider(p) when p in @providers, do: p
  defp parse_provider("github"), do: :github
  defp parse_provider("azure_devops"), do: :azure_devops
  defp parse_provider(_), do: nil

  defp parse_sync_type(s) when s in @sync_types, do: s
  defp parse_sync_type("bidirectional"), do: :bidirectional
  defp parse_sync_type("push"), do: :push
  defp parse_sync_type("pull"), do: :pull
  defp parse_sync_type(_), do: :bidirectional

  defp adapter_for(:github), do: ApmV4.UPM.Adapters.GitHubAdapter
  defp adapter_for(:azure_devops), do: ApmV4.UPM.Adapters.AzureDevOpsAdapter

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
      {:error, reason} -> Logger.error("[UPM.VCSIntegrationStore] Persist failed: #{inspect(reason)}")
    end
  end

  defp broadcast_update do
    integrations = :ets.tab2list(@table) |> Enum.map(fn {_id, r} -> r end)

    Phoenix.PubSub.broadcast(
      ApmV4.PubSub,
      @pubsub_topic,
      {:upm_vcs_integrations_updated, integrations}
    )
  end

  defp generate_id(attrs) do
    project_id = get_attr(attrs, :project_id) || get_attr(attrs, "project_id") || ""
    provider = get_attr(attrs, :provider) || get_attr(attrs, "provider") || ""
    :crypto.hash(:sha256, "#{project_id}:#{provider}") |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp get_attr(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp record_to_map(record) do
    %{
      id: record.id,
      project_id: record.project_id,
      provider: record.provider,
      repo_url: record.repo_url,
      default_branch: record.default_branch,
      qa_branch: record.qa_branch,
      staging_branch: record.staging_branch,
      prod_branch: record.prod_branch,
      sync_type: record.sync_type,
      resource_group: record.resource_group,
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
