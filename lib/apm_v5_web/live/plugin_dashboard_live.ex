defmodule ApmV5Web.PluginDashboardLive do
  use ApmV5Web, :live_view
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

  attr :active, :string, default: "false"
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, required: true

  defp nav_item(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-colors",
        @active == "true" && "bg-primary text-primary-content font-medium" ||
          "text-base-content/70 hover:bg-base-200 hover:text-base-content"
      ]}
    >
      <.icon name={@icon} class="size-4 flex-shrink-0" />
      <span>{@label}</span>
    </a>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-100 overflow-hidden">
      <aside class="w-52 bg-base-200 border-r border-base-300 flex flex-col flex-shrink-0">
        <div class="p-3 border-b border-base-300">
          <a href="/" class="font-mono font-bold text-sm text-base-content">CCEM APM</a>
          <div class="text-xs text-base-content/40 mt-0.5">v4.0.0</div>
        </div>
        <nav class="flex-1 p-2 space-y-1 overflow-y-auto">
          <.nav_item icon="hero-squares-2x2" label="Dashboard" active="false" href="/" />
          <.nav_item icon="hero-globe-alt" label="All Projects" active="false" href="/apm-all" />
          <.nav_item icon="hero-rectangle-group" label="Formations" active="false" href="/formation" />
          <.nav_item icon="hero-clock" label="Timeline" active="false" href="/timeline" />
          <.nav_item icon="hero-bell" label="Notifications" active="false" href="/notifications" />
          <.nav_item icon="hero-queue-list" label="Background Tasks" active="false" href="/tasks" />
          <.nav_item icon="hero-magnifying-glass" label="Project Scanner" active="false" href="/scanner" />
          <.nav_item icon="hero-bolt" label="Actions" active="false" href="/actions" />
          <.nav_item icon="hero-sparkles" label="Skills" active="false" href="/skills" />
          <.nav_item icon="hero-arrow-path" label="Ralph" active="false" href="/ralph" />
          <.nav_item icon="hero-signal" label="Ports" active="false" href="/ports" />
          <.nav_item icon="hero-chart-bar" label="Analytics" active="false" href="/analytics" />
          <.nav_item icon="hero-heart" label="Health" active="false" href="/health" />
          <.nav_item icon="hero-chat-bubble-left-right" label="Conversations" active="false" href="/conversations" />
          <.nav_item icon="hero-puzzle-piece" label="Plugins" active="true" href="/plugins" />
          <.nav_item icon="hero-book-open" label="Docs" active="false" href="/docs" />
        </nav>
      </aside>

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
    """
  end
end
