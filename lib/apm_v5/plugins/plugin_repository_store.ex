defmodule ApmV5.Plugins.PluginRepositoryStore do
  @moduledoc """
  GenServer + ETS store for plugin repository (marketplace) metadata.

  Seeds from `~/.claude/plugins/known_marketplaces.json` on init.
  Built-in repos (seeded from the JSON file) are protected from deletion.

  ## ETS Table
  - Name: `:plugin_repo_store`
  - Key: marketplace name (String.t)
  - Value: repository metadata map
  """

  use GenServer
  require Logger

  @table :plugin_repo_store

  # ── Public API ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List all known plugin repositories, sorted by name."
  @spec list_repos() :: [map()]
  def list_repos do
    case :ets.info(@table) do
      :undefined -> []
      _ -> :ets.tab2list(@table) |> Enum.map(fn {_k, v} -> v end) |> Enum.sort_by(& &1.name)
    end
  end

  @doc "Get a single repository by name."
  @spec get_repo(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_repo(name) do
    case :ets.lookup(@table, name) do
      [{^name, repo}] -> {:ok, repo}
      [] -> {:error, :not_found}
    end
  end

  @doc "Add a new repository. Requires `:name` and `:url` in the params map."
  @spec add_repo(map()) :: {:ok, map()} | {:error, term()}
  def add_repo(params) when is_map(params) do
    GenServer.call(__MODULE__, {:add_repo, params})
  end

  @doc "Update an existing repository by name."
  @spec update_repo(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_repo(name, updates) when is_binary(name) and is_map(updates) do
    GenServer.call(__MODULE__, {:update_repo, name, updates})
  end

  @doc "Delete a repository by name. Built-in repos cannot be deleted."
  @spec delete_repo(String.t()) :: :ok | {:error, term()}
  def delete_repo(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:delete_repo, name})
  end

  @doc "Update plugin_count and last_synced for a repository."
  @spec sync_repo_stats(String.t(), map()) :: :ok
  def sync_repo_stats(name, stats) when is_binary(name) and is_map(stats) do
    GenServer.cast(__MODULE__, {:sync_repo_stats, name, stats})
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, read_concurrency: true])
    send(self(), :seed)
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:seed, state) do
    seed_from_known_marketplaces()
    {:noreply, state}
  end

  @impl true
  def handle_call({:add_repo, params}, _from, state) do
    name = Map.get(params, :name) || Map.get(params, "name")
    url = Map.get(params, :url) || Map.get(params, "url")

    cond do
      is_nil(name) or name == "" ->
        {:reply, {:error, :name_required}, state}

      is_nil(url) or url == "" ->
        {:reply, {:error, :url_required}, state}

      true ->
        repo = %{
          name: name,
          url: url,
          source: Map.get(params, :source) || Map.get(params, "source", "custom"),
          description: Map.get(params, :description) || Map.get(params, "description", ""),
          builtin: false,
          plugin_count: 0,
          last_synced: nil,
          added_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        :ets.insert(@table, {name, repo})
        Logger.info("[PluginRepositoryStore] Added repository: #{name}")

        Phoenix.PubSub.broadcast(
          ApmV5.PubSub,
          "apm:plugin_repos",
          {:repo_added, name}
        )

        {:reply, {:ok, repo}, state}
    end
  end

  @impl true
  def handle_call({:update_repo, name, updates}, _from, state) do
    case :ets.lookup(@table, name) do
      [{^name, repo}] ->
        # Only allow updating non-structural fields
        updated =
          repo
          |> maybe_update(:url, updates)
          |> maybe_update(:description, updates)
          |> maybe_update(:source, updates)

        :ets.insert(@table, {name, updated})

        Phoenix.PubSub.broadcast(
          ApmV5.PubSub,
          "apm:plugin_repos",
          {:repo_updated, name}
        )

        {:reply, {:ok, updated}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:delete_repo, name}, _from, state) do
    case :ets.lookup(@table, name) do
      [{^name, %{builtin: true}}] ->
        {:reply, {:error, :builtin_protected}, state}

      [{^name, _repo}] ->
        :ets.delete(@table, name)
        Logger.info("[PluginRepositoryStore] Deleted repository: #{name}")

        Phoenix.PubSub.broadcast(
          ApmV5.PubSub,
          "apm:plugin_repos",
          {:repo_deleted, name}
        )

        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_cast({:sync_repo_stats, name, stats}, state) do
    case :ets.lookup(@table, name) do
      [{^name, repo}] ->
        updated =
          repo
          |> Map.put(:plugin_count, Map.get(stats, :plugin_count, repo.plugin_count))
          |> Map.put(:last_synced, DateTime.utc_now() |> DateTime.to_iso8601())

        :ets.insert(@table, {name, updated})

      [] ->
        :ok
    end

    {:noreply, state}
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  @spec seed_from_known_marketplaces() :: :ok
  defp seed_from_known_marketplaces do
    path = Path.expand("~/.claude/plugins/known_marketplaces.json")

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} when is_map(data) ->
            Enum.each(data, fn {name, info} ->
              source_info = Map.get(info, "source", %{})

              repo = %{
                name: name,
                url: Map.get(source_info, "repo", ""),
                source: Map.get(source_info, "source", "unknown"),
                description: "",
                builtin: true,
                plugin_count: count_marketplace_plugins(name),
                last_synced: Map.get(info, "lastUpdated"),
                added_at: Map.get(info, "lastUpdated", DateTime.utc_now() |> DateTime.to_iso8601())
              }

              :ets.insert(@table, {name, repo})
            end)

            Logger.info(
              "[PluginRepositoryStore] Seeded #{map_size(data)} repositories from known_marketplaces.json"
            )

          _ ->
            Logger.debug("[PluginRepositoryStore] Could not parse known_marketplaces.json")
        end

      {:error, reason} ->
        Logger.debug("[PluginRepositoryStore] Cannot read known_marketplaces.json: #{reason}")
    end

    :ok
  end

  @spec count_marketplace_plugins(String.t()) :: non_neg_integer()
  defp count_marketplace_plugins(marketplace_name) do
    base = Path.expand("~/.claude/plugins/marketplaces")
    json_path = Path.join([base, marketplace_name, ".claude-plugin", "marketplace.json"])

    case File.read(json_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"plugins" => plugins}} when is_list(plugins) -> length(plugins)
          _ -> 0
        end

      {:error, _} ->
        0
    end
  end

  @spec maybe_update(map(), atom(), map()) :: map()
  defp maybe_update(repo, key, updates) do
    str_key = Atom.to_string(key)

    cond do
      Map.has_key?(updates, key) -> Map.put(repo, key, Map.get(updates, key))
      Map.has_key?(updates, str_key) -> Map.put(repo, key, Map.get(updates, str_key))
      true -> repo
    end
  end
end
