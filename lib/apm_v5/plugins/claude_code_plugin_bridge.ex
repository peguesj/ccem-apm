defmodule ApmV5.Plugins.ClaudeCodePluginBridge do
  @moduledoc """
  Read-only bridge to Claude Code's native plugin ecosystem.

  Scans `~/.claude/plugins/` for installed plugins, merges marketplace
  registry metadata, and exposes a unified view via ETS.

  ## ETS Table
  - Name: `:cc_plugin_bridge`
  - Key: `"plugin@marketplace"` string
  - Value: enriched plugin metadata map
  """

  use GenServer
  require Logger

  @table :cc_plugin_bridge
  @refresh_ms 300_000

  # ── Public API ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List all discovered Claude Code plugins, sorted by name."
  @spec list_cc_plugins() :: [map()]
  def list_cc_plugins do
    case :ets.info(@table) do
      :undefined -> []
      _ -> :ets.tab2list(@table) |> Enum.map(fn {_k, v} -> v end) |> Enum.sort_by(& &1.name)
    end
  end

  @doc "Get a single Claude Code plugin by its `plugin@marketplace` key."
  @spec get_cc_plugin(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_cc_plugin(key) do
    case :ets.lookup(@table, key) do
      [{^key, plugin}] -> {:ok, plugin}
      [] -> {:error, :not_found}
    end
  end

  @doc "List known marketplace sources."
  @spec list_marketplaces() :: [map()]
  def list_marketplaces, do: GenServer.call(__MODULE__, :list_marketplaces)

  @doc "Return a summary of the Claude Code plugin landscape."
  @spec get_summary() :: map()
  def get_summary do
    plugins = list_cc_plugins()
    enabled = Enum.count(plugins, & &1.enabled)
    marketplaces = plugins |> Enum.map(& &1.marketplace) |> Enum.uniq()

    %{
      total_installed: length(plugins),
      enabled_count: enabled,
      disabled_count: length(plugins) - enabled,
      marketplace_count: length(marketplaces),
      marketplaces: marketplaces
    }
  end

  @doc "Force an immediate rescan of Claude Code plugins."
  @spec rescan() :: :ok
  def rescan, do: GenServer.cast(__MODULE__, :rescan)

  # ── GenServer Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, read_concurrency: true])
    send(self(), :initial_scan)
    {:ok, %{table: table, marketplaces: %{}}}
  end

  @impl true
  def handle_info(:initial_scan, state) do
    state = do_scan(state)
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    state = do_scan(state)
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:rescan, state) do
    state = do_scan(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:list_marketplaces, _from, state) do
    result =
      state.marketplaces
      |> Enum.map(fn {name, info} -> Map.put(info, :name, name) end)
      |> Enum.sort_by(& &1.name)

    {:reply, result, state}
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  @spec do_scan(map()) :: map()
  defp do_scan(state) do
    installed = read_installed_plugins()
    marketplaces_map = read_marketplaces()
    enabled_map = read_enabled_status()
    registry_map = read_marketplace_registries()

    plugins = merge_plugins(installed, enabled_map, registry_map)

    Enum.each(plugins, fn plugin ->
      :ets.insert(@table, {plugin.key, plugin})
    end)

    Logger.debug(
      "[ClaudeCodePluginBridge] Scanned #{length(plugins)} Claude Code plugins from #{map_size(marketplaces_map)} marketplaces"
    )

    Phoenix.PubSub.broadcast(
      ApmV5.PubSub,
      "apm:cc_plugins",
      {:cc_plugins_updated, length(plugins)}
    )

    %{state | marketplaces: marketplaces_map}
  end

  @spec read_installed_plugins() :: map()
  defp read_installed_plugins do
    path = Path.expand("~/.claude/plugins/installed_plugins.json")

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"plugins" => plugins}} when is_map(plugins) -> plugins
          _ -> %{}
        end

      {:error, reason} ->
        Logger.debug("[ClaudeCodePluginBridge] Cannot read installed_plugins.json: #{reason}")
        %{}
    end
  end

  @spec read_marketplaces() :: map()
  defp read_marketplaces do
    path = Path.expand("~/.claude/plugins/known_marketplaces.json")

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} when is_map(data) ->
            Map.new(data, fn {name, info} ->
              source = get_in(info, ["source"]) || %{}

              {name,
               %{
                 source: Map.get(source, "source", "unknown"),
                 url: Map.get(source, "repo", ""),
                 install_location: Map.get(info, "installLocation", ""),
                 last_updated: Map.get(info, "lastUpdated", "")
               }}
            end)

          _ ->
            %{}
        end

      {:error, reason} ->
        Logger.debug("[ClaudeCodePluginBridge] Cannot read known_marketplaces.json: #{reason}")
        %{}
    end
  end

  @spec read_enabled_status() :: map()
  defp read_enabled_status do
    path = Path.expand("~/.claude/settings.json")

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"enabledPlugins" => enabled}} when is_map(enabled) -> enabled
          _ -> %{}
        end

      {:error, reason} ->
        Logger.debug("[ClaudeCodePluginBridge] Cannot read settings.json: #{reason}")
        %{}
    end
  end

  @spec read_marketplace_registries() :: map()
  defp read_marketplace_registries do
    base = Path.expand("~/.claude/plugins/marketplaces")

    case File.ls(base) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.reduce(%{}, fn dir_name, acc ->
          marketplace_json = Path.join([base, dir_name, ".claude-plugin", "marketplace.json"])

          case File.read(marketplace_json) do
            {:ok, content} ->
              case Jason.decode(content) do
                {:ok, %{"plugins" => plugins}} when is_list(plugins) ->
                  plugin_map =
                    Map.new(plugins, fn p ->
                      {Map.get(p, "name", "unknown"), normalize_marketplace_plugin(p)}
                    end)

                  Map.put(acc, dir_name, plugin_map)

                _ ->
                  acc
              end

            {:error, _} ->
              acc
          end
        end)

      {:error, reason} ->
        Logger.debug("[ClaudeCodePluginBridge] Cannot list marketplace dirs: #{reason}")
        %{}
    end
  end

  @spec normalize_marketplace_plugin(map()) :: map()
  defp normalize_marketplace_plugin(p) do
    author =
      case Map.get(p, "author") do
        %{"name" => name} -> name
        _ -> nil
      end

    %{
      description: Map.get(p, "description"),
      author: author,
      category: Map.get(p, "category"),
      homepage: Map.get(p, "homepage"),
      version: Map.get(p, "version")
    }
  end

  @spec merge_plugins(map(), map(), map()) :: [map()]
  defp merge_plugins(installed, enabled_map, registry_map) do
    Enum.flat_map(installed, fn {key, records} ->
      case records do
        [record | _] when is_map(record) ->
          {plugin_name, marketplace_name} = split_plugin_key(key)
          marketplace_meta = get_marketplace_meta(registry_map, marketplace_name, plugin_name)
          install_path_meta = read_install_path_plugin_json(Map.get(record, "installPath"))

          [
            %{
              key: key,
              name: plugin_name,
              marketplace: marketplace_name,
              version: Map.get(record, "version", "unknown"),
              install_path: Map.get(record, "installPath"),
              git_commit_sha: Map.get(record, "gitCommitSha"),
              installed_at: Map.get(record, "installedAt"),
              last_updated: Map.get(record, "lastUpdated"),
              enabled: Map.get(enabled_map, key) == true,
              description:
                marketplace_meta[:description] || install_path_meta[:description],
              author:
                marketplace_meta[:author] || install_path_meta[:author],
              category: marketplace_meta[:category],
              skills: install_path_meta[:skills] || [],
              scope: Map.get(record, "scope", "user")
            }
          ]

        _ ->
          []
      end
    end)
  end

  @spec split_plugin_key(String.t()) :: {String.t(), String.t()}
  defp split_plugin_key(key) do
    case String.split(key, "@", parts: 2) do
      [name, marketplace] -> {name, marketplace}
      [name] -> {name, "unknown"}
    end
  end

  @spec get_marketplace_meta(map(), String.t(), String.t()) :: map()
  defp get_marketplace_meta(registry_map, marketplace_name, plugin_name) do
    case get_in(registry_map, [marketplace_name, plugin_name]) do
      nil -> %{}
      meta -> meta
    end
  end

  @spec read_install_path_plugin_json(String.t() | nil) :: map()
  defp read_install_path_plugin_json(nil), do: %{}

  defp read_install_path_plugin_json(install_path) do
    json_path = Path.join([install_path, ".claude-plugin", "plugin.json"])

    case File.read(json_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} when is_map(data) ->
            author =
              case Map.get(data, "author") do
                %{"name" => name} -> name
                _ -> nil
              end

            %{
              description: Map.get(data, "description"),
              author: author,
              skills: Map.get(data, "skills", [])
            }

          _ ->
            %{}
        end

      {:error, _} ->
        %{}
    end
  end
end
