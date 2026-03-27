defmodule ApmV5Web.PluginDashboardLive do
  @moduledoc """
  LiveView for the plugin scanner dashboard at /plugins.

  Lists discovered Claude Code plugins, MCP server configurations, and registered
  APM Engine plugins (e.g. Plane PM).  Subscribes to the `"apm:plugins"` PubSub
  topic so registrations broadcast in real-time.
  """

  use ApmV5Web, :live_view

  import ApmV5Web.Components.GettingStartedWizard

  require Logger

  @pubsub_topic "apm:plugins"
  @integrations_topic "apm:integrations"

  # ── Priority / state colour maps (passed as assigns) ────────────────────────
  defp priority_class("urgent"), do: "badge-error"
  defp priority_class("high"), do: "badge-warning"
  defp priority_class("medium"), do: "badge-info"
  defp priority_class(_), do: "badge-ghost"

  defp state_class("Backlog"), do: "badge-ghost"
  defp state_class("Todo"), do: "badge-info"
  defp state_class("In Progress"), do: "badge-warning"
  defp state_class("Done"), do: "badge-success"
  defp state_class("Cancelled"), do: "badge-error"
  defp state_class(_), do: "badge-ghost"

  # ── mount ────────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(120_000, self(), :refresh)
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic)
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @integrations_topic)
    end

    {:ok, assign_data(socket) |> assign(active_tab: "mcp", selected_issue: nil, current_path: "/plugins")}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :integrations_tab}} = socket) do
    {:noreply, assign(socket, active_tab: "registered", current_path: "/integrations")}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, current_path: "/plugins")}
  end

  # ── events ───────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("rescan", _params, socket) do
    ApmV5.PluginScanner.rescan()
    Process.sleep(300)
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    socket = assign(socket, active_tab: tab, selected_issue: nil)

    socket =
      if tab == "plane" do
        load_plane_issues(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_issue", %{"id" => id}, socket) do
    issue =
      socket.assigns[:plane_issues]
      |> Kernel.||([])
      |> Enum.find(&(to_string(&1.id) == id))

    {:noreply, assign(socket, selected_issue: issue)}
  end

  @impl true
  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign(socket, selected_issue: nil)}
  end

  @impl true
  def handle_event("reload_plane", _params, socket) do
    {:noreply, load_plane_issues(socket)}
  end

  # ── info ─────────────────────────────────────────────────────────────────────

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_info({:plugin_registered, _meta}, socket) do
    {:noreply, assign_registered_plugins(socket)}
  end

  @impl true
  def handle_info({:integration_registered, _meta}, socket) do
    {:noreply, assign_integrations(socket)}
  end

  # ── private helpers ──────────────────────────────────────────────────────────

  defp assign_data(socket) do
    socket
    |> assign(
      mcp_servers: ApmV5.PluginScanner.get_mcp_servers(),
      plugins: ApmV5.PluginScanner.get_plugins(),
      page_title: "Plugins"
    )
    |> assign_registered_plugins()
    |> assign_integrations()
  end

  defp assign_registered_plugins(socket) do
    registered = ApmV5.Plugins.PluginRegistry.list_plugins()
    assign(socket, registered_plugins: registered)
  end

  defp assign_integrations(socket) do
    integrations = ApmV5.Integrations.IntegrationRegistry.list_integrations()
    assign(socket, integrations: integrations)
  end

  defp load_plane_issues(socket) do
    case ApmV5.Plugins.PluginRegistry.call_plugin_action("plane", "board_state", %{}) do
      {:ok, %{board: board, total: total}} ->
        all_issues = Enum.flat_map(board, & &1.issues)
        assign(socket, plane_board: board, plane_issues: all_issues, plane_total: total, plane_error: nil)

      {:error, {:not_found, _}} ->
        assign(socket, plane_board: [], plane_issues: [], plane_total: 0, plane_error: "Plane plugin not registered")

      {:error, reason} ->
        assign(socket, plane_board: [], plane_issues: [], plane_total: 0, plane_error: inspect(reason))
    end
  end

  # ── render ───────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> Map.put_new(:plane_board, [])
      |> Map.put_new(:plane_issues, [])
      |> Map.put_new(:plane_total, 0)
      |> Map.put_new(:plane_error, nil)
      |> Map.put_new(:registered_plugins, [])
      |> Map.put_new(:integrations, [])

    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <.sidebar_nav current_path={@current_path} />

      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Header --%>
        <header class="bg-base-200 border-b border-base-300 px-4 py-2 flex items-center justify-between flex-shrink-0">
          <h1 class="font-semibold text-sm">Plugins & MCP Servers</h1>
          <button phx-click="rescan" class="btn btn-xs btn-ghost gap-1">
            <.icon name="hero-arrow-path" class="size-3.5" /> Rescan
          </button>
        </header>

        <%!-- Tab bar --%>
        <div class="border-b border-base-300 bg-base-200 px-4 flex gap-2 flex-shrink-0">
          <button
            phx-click="switch_tab"
            phx-value-tab="mcp"
            class={"tab tab-bordered tab-sm #{if @active_tab == "mcp", do: "tab-active", else: ""}"}
          >
            MCP Servers ({length(@mcp_servers)})
          </button>
          <button
            phx-click="switch_tab"
            phx-value-tab="discovered"
            class={"tab tab-bordered tab-sm #{if @active_tab == "discovered", do: "tab-active", else: ""}"}
          >
            Discovered ({length(@plugins)})
          </button>
          <button
            phx-click="switch_tab"
            phx-value-tab="registered"
            class={"tab tab-bordered tab-sm #{if @active_tab == "registered", do: "tab-active", else: ""}"}
          >
            Engine ({length(@registered_plugins)})
          </button>
          <button
            phx-click="switch_tab"
            phx-value-tab="plane"
            class={"tab tab-bordered tab-sm #{if @active_tab == "plane", do: "tab-active", else: ""}"}
          >
            Plane PM
          </button>
          <button
            phx-click="switch_tab"
            phx-value-tab="integrations"
            class={"tab tab-bordered tab-sm #{if @active_tab == "integrations", do: "tab-active", else: ""}"}
          >
            Integrations ({length(@integrations)})
          </button>
        </div>

        <div class="flex-1 overflow-y-auto p-4">
          <%!-- MCP Servers tab --%>
          <div :if={@active_tab == "mcp"} class="space-y-4">
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
          </div>

          <%!-- Discovered Plugins tab --%>
          <div :if={@active_tab == "discovered"} class="space-y-4">
            <div class="bg-base-200 rounded-lg p-4">
              <h2 class="text-sm font-semibold mb-3">Discovered Plugins ({length(@plugins)})</h2>
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

          <%!-- Engine Plugins tab --%>
          <div :if={@active_tab == "registered"} class="space-y-4">
            <div class="bg-base-200 rounded-lg p-4">
              <h2 class="text-sm font-semibold mb-3">Registered Engine Plugins ({length(@registered_plugins)})</h2>
              <div :if={@registered_plugins == []} class="text-xs text-base-content/40">
                No plugins registered in PluginRegistry yet.
              </div>
              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
                <div :for={plugin <- @registered_plugins} class="card card-compact bg-base-100 shadow">
                  <div class="card-body">
                    <div class="flex items-center justify-between">
                      <h3 class="card-title text-sm">{plugin.name}</h3>
                      <span class="badge badge-xs badge-primary">v{plugin.version}</span>
                    </div>
                    <p class="text-xs text-base-content/60">{plugin.description}</p>
                    <div class="mt-2">
                      <p class="text-xs font-semibold mb-1">Actions ({length(plugin.endpoints)})</p>
                      <div class="flex flex-wrap gap-1">
                        <span :for={ep <- plugin.endpoints} class="badge badge-xs badge-outline">
                          {ep.action}
                        </span>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <%!-- Integrations tab --%>
          <div :if={@active_tab == "integrations"} class="space-y-4">
            <div class="bg-base-200 rounded-lg p-4">
              <h2 class="text-sm font-semibold mb-3">Registered Integrations ({length(@integrations)})</h2>
              <div :if={@integrations == []} class="text-xs text-base-content/40">
                No integrations registered. Check IntegrationRegistry startup.
              </div>
              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
                <div :for={integration <- @integrations} class="card card-compact bg-base-100 shadow">
                  <div class="card-body">
                    <div class="flex items-center justify-between">
                      <h3 class="card-title text-sm">{integration.name}</h3>
                      <div class="flex gap-1">
                        <span class="badge badge-xs badge-outline">{integration.protocol}</span>
                        <span class={[
                          "badge badge-xs",
                          case integration.status do
                            :connected -> "badge-success"
                            :degraded -> "badge-warning"
                            _ -> "badge-ghost"
                          end
                        ]}>
                          {integration.status}
                        </span>
                        <span class="badge badge-xs badge-primary">v{integration.version}</span>
                      </div>
                    </div>
                    <p class="text-xs text-base-content/60">{integration.description}</p>
                    <div class="mt-2">
                      <p class="text-xs font-semibold mb-1">Actions ({length(integration.endpoints)})</p>
                      <div class="flex flex-wrap gap-1">
                        <span :for={ep <- integration.endpoints} class="badge badge-xs badge-outline">
                          {ep.action}
                        </span>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <%!-- Plane PM tab --%>
          <div :if={@active_tab == "plane"} class="space-y-4">
            <div class="flex items-center justify-between">
              <h2 class="text-sm font-semibold">Plane PM — CCEM Issues ({@plane_total})</h2>
              <button phx-click="reload_plane" class="btn btn-xs btn-ghost gap-1">
                <.icon name="hero-arrow-path" class="size-3.5" /> Reload
              </button>
            </div>

            <div :if={@plane_error} class="alert alert-error text-xs">
              <.icon name="hero-exclamation-triangle" class="size-4" />
              <span>{@plane_error}</span>
            </div>

            <div :if={@plane_board == [] and is_nil(@plane_error)} class="text-xs text-base-content/40 py-8 text-center">
              Click a state column or Reload to fetch issues from Plane.
            </div>

            <%!-- Kanban board --%>
            <div :if={@plane_board != []} class="flex gap-3 overflow-x-auto pb-2">
              <div
                :for={col <- @plane_board}
                class="flex-shrink-0 w-64 bg-base-200 rounded-lg p-3"
              >
                <div class="flex items-center justify-between mb-2">
                  <span class={"badge badge-sm #{state_class(col.state)}"}>
                    {col.state}
                  </span>
                  <span class="text-xs text-base-content/50">{col.count}</span>
                </div>

                <div class="space-y-2">
                  <button
                    :for={issue <- col.issues}
                    phx-click="select_issue"
                    phx-value-id={issue.id}
                    class="w-full text-left bg-base-100 rounded p-2 hover:bg-base-300 transition-colors"
                  >
                    <div class="flex items-start justify-between gap-1">
                      <span class="text-xs font-mono text-base-content/50">{issue.sequence_id}</span>
                      <span :if={issue.priority && issue.priority != "none"} class={"badge badge-xs #{priority_class(issue.priority)}"}>
                        {issue.priority}
                      </span>
                    </div>
                    <p class="text-xs mt-1 line-clamp-2">{issue.name}</p>
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Issue detail slide-in drawer --%>
      <div
        :if={@selected_issue}
        class="fixed inset-y-0 right-0 w-96 bg-base-100 shadow-2xl border-l border-base-300 z-50 flex flex-col"
      >
        <div class="flex items-center justify-between p-4 border-b border-base-300">
          <span class="font-mono text-sm text-base-content/60">{@selected_issue.sequence_id}</span>
          <button phx-click="close_drawer" class="btn btn-ghost btn-xs btn-circle">
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <div class="flex-1 overflow-y-auto p-4 space-y-4">
          <h2 class="font-semibold text-sm">{@selected_issue.name}</h2>

          <div class="flex flex-wrap gap-2">
            <span class={"badge badge-sm #{state_class(@selected_issue.state_name)}"}>
              {@selected_issue.state_name}
            </span>
            <span :if={@selected_issue.priority && @selected_issue.priority != "none"}
              class={"badge badge-sm #{priority_class(@selected_issue.priority)}"}>
              {@selected_issue.priority}
            </span>
          </div>

          <div :if={@selected_issue.description && @selected_issue.description != ""}>
            <p class="text-xs font-semibold mb-1 text-base-content/60">Description</p>
            <p class="text-xs text-base-content/80 whitespace-pre-wrap">{@selected_issue.description}</p>
          </div>

          <div class="text-xs text-base-content/40 space-y-1">
            <p>Created: {@selected_issue.created_at}</p>
            <p>Updated: {@selected_issue.updated_at}</p>
            <p :if={@selected_issue.completed_at}>Completed: {@selected_issue.completed_at}</p>
          </div>
        </div>
      </div>
      <%!-- Drawer overlay --%>
      <div
        :if={@selected_issue}
        phx-click="close_drawer"
        class="fixed inset-0 bg-black/30 z-40"
      />
    </div>
    <.wizard page="welcome" dom_id="ccem-wizard-welcome-plugins" />
    """
  end
end
