defmodule ApmV5.PluginScanner do
  @moduledoc """
  GenServer that scans ~/.claude/settings.json for MCP servers and ~/.claude-plugin/ for plugins.
  Refreshes every 2 minutes. Exposes MCP server list and plugin registry.
  """
  use GenServer
  require Logger

  @refresh_interval_ms 120_000

  # --- Client API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec get_mcp_servers() :: [map()]
  def get_mcp_servers do
    GenServer.call(__MODULE__, :get_mcp_servers)
  end

  @spec get_plugins() :: [map()]
  def get_plugins do
    GenServer.call(__MODULE__, :get_plugins)
  end

  @spec rescan() :: :ok
  def rescan do
    GenServer.cast(__MODULE__, :rescan)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    state = %{mcp_servers: [], plugins: [], last_scan: nil}
    schedule_refresh()
    {:ok, state, {:continue, :initial_scan}}
  end

  @impl true
  def handle_continue(:initial_scan, state) do
    {:noreply, do_scan(state)}
  end

  @impl true
  def handle_call(:get_mcp_servers, _from, state) do
    {:reply, state.mcp_servers, state}
  end

  @impl true
  def handle_call(:get_plugins, _from, state) do
    {:reply, state.plugins, state}
  end

  @impl true
  def handle_cast(:rescan, state) do
    {:noreply, do_scan(state)}
  end

  @impl true
  def handle_info(:refresh, state) do
    schedule_refresh()
    {:noreply, do_scan(state)}
  end

  # --- Private helpers ---

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end

  defp do_scan(state) do
    mcp_servers = scan_mcp_servers()
    plugins = scan_plugins()
    %{state | mcp_servers: mcp_servers, plugins: plugins, last_scan: DateTime.utc_now()}
  end

  defp scan_mcp_servers do
    settings_path = Path.expand("~/.claude/settings.json")

    with {:ok, content} <- File.read(settings_path),
         {:ok, parsed} <- Jason.decode(content),
         mcp_servers when is_map(mcp_servers) <- Map.get(parsed, "mcpServers", %{}) do
      Enum.map(mcp_servers, fn {name, config} ->
        %{
          name: name,
          type: Map.get(config, "type", "stdio"),
          command: Map.get(config, "command", ""),
          args: Map.get(config, "args", []),
          env: Map.get(config, "env", %{}),
          enabled: true
        }
      end)
    else
      _ -> []
    end
  end

  defp scan_plugins do
    plugin_dirs = [
      Path.expand("~/.claude-plugin"),
      Path.expand("~/.claude/plugins")
    ]

    plugin_dirs
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(&list_plugins_in_dir/1)
  end

  defp list_plugins_in_dir(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(fn entry ->
          plugin_path = Path.join(dir, entry)
          manifest_path = Path.join(plugin_path, "plugin.json")

          case File.read(manifest_path) do
            {:ok, content} ->
              case Jason.decode(content) do
                {:ok, manifest} ->
                  %{
                    name: Map.get(manifest, "name", entry),
                    version: Map.get(manifest, "version", "?"),
                    description: Map.get(manifest, "description", ""),
                    path: plugin_path
                  }
                _ ->
                  %{name: entry, version: "?", description: "No manifest", path: plugin_path}
              end
            _ ->
              %{name: entry, version: "?", description: "No manifest", path: plugin_path}
          end
        end)

      {:error, _} ->
        []
    end
  end
end
