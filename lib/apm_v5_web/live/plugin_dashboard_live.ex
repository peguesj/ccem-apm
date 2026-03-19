defmodule ApmV5Web.PluginDashboardLive do
  @moduledoc """
  LiveView for the plugin scanner dashboard at /plugins.

  Lists discovered Claude Code plugins and MCP server configurations
  found by PluginScanner in registered project directories.
  """

  use ApmV5Web, :live_view

  import ApmV5Web.Components.GettingStartedWizard

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(120_000, self(), :refresh)
    end
    {:ok, assign_data(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_event("rescan", _params, socket) do
    ApmV5.PluginScanner.rescan()
    Process.sleep(300)
    {:noreply, assign_data(socket)}
  end

  defp assign_data(socket) do
    mcp_servers = ApmV5.PluginScanner.get_mcp_servers()
    plugins = ApmV5.PluginScanner.get_plugins()
    assign(socket, mcp_servers: mcp_servers, plugins: plugins, page_title: "Plugins")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-100 overflow-hidden">
      <.sidebar_nav current_path="/plugins" />

      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="bg-base-200 border-b border-base-300 px-4 py-2 flex items-center justify-between flex-shrink-0">
          <h1 class="font-semibold text-sm">Plugins & MCP Servers</h1>
          <button phx-click="rescan" class="btn btn-xs btn-ghost gap-1">
            <.icon name="hero-arrow-path" class="size-3.5" /> Rescan
          </button>
        </header>

        <div class="flex-1 overflow-y-auto p-4 space-y-4">
          <%!-- MCP Servers --%>
          <div class="bg-base-200 rounded-lg p-4">
            <h2 class="text-sm font-semibold mb-3">MCP Servers ({length(@mcp_servers)})</h2>
            <div :if={@mcp_servers == []} class="text-xs text-base-content/40">
              No MCP servers found in ~/.claude/settings.json
            </div>
            <div class="overflow-x-auto">
              <table class="table table-xs w-full">
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Type</th>
                    <th>Command</th>
                    <th>Args</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={server <- @mcp_servers}>
                    <td class="font-medium">{server.name}</td>
                    <td><span class="badge badge-xs badge-outline">{server.type}</span></td>
                    <td class="font-mono text-xs">{server.command}</td>
                    <td class="font-mono text-xs text-base-content/60">
                      {Enum.join(server.args, " ")}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <%!-- Plugins --%>
          <div class="bg-base-200 rounded-lg p-4">
            <h2 class="text-sm font-semibold mb-3">Plugins ({length(@plugins)})</h2>
            <div :if={@plugins == []} class="text-xs text-base-content/40">
              No plugins found in ~/.claude-plugin/ or ~/.claude/plugins/
            </div>
            <div class="overflow-x-auto">
              <table class="table table-xs w-full">
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Version</th>
                    <th>Description</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={plugin <- @plugins}>
                    <td class="font-medium">{plugin.name}</td>
                    <td><span class="badge badge-xs">{plugin.version}</span></td>
                    <td class="text-base-content/60">{plugin.description}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
    </div>
    <.wizard page="welcome" dom_id="ccem-wizard-welcome-plugins" />
    """
  end
end
