defmodule ApmV5Web.PluginDashboardLive do
  @moduledoc """
  LiveView for /plugins (Engine plugins + MCP + Discovered + Plane PM)
  and /integrations (AG-UI, AgentLock, and any registered integration adapters).

  Both routes share this LiveView but target different active tabs:
    - /plugins       → :index         → active_tab: "mcp"
    - /integrations  → :integrations_tab → active_tab: "integrations"

  Interactive features:
    - Engine Plugins: action runner panel (select plugin → pick action → fill params → invoke → see result)
    - Integrations: event runner + live status check + connect/disconnect controls
    - Plane PM: Kanban board with issue detail drawer
  """

  use ApmV5Web, :live_view

  import ApmV5Web.Components.GettingStartedWizard

  require Logger

  @pubsub_topic "apm:plugins"
  @integrations_topic "apm:integrations"

  # ── Priority / state colour helpers ─────────────────────────────────────────

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

  defp protocol_class(:ag_ui), do: "badge-secondary"
  defp protocol_class(:custom), do: "badge-accent"
  defp protocol_class(:rest), do: "badge-info"
  defp protocol_class(:webhook), do: "badge-warning"
  defp protocol_class(_), do: "badge-ghost"

  defp status_class(:connected), do: "badge-success"
  defp status_class(:degraded), do: "badge-warning"
  defp status_class(:initializing), do: "badge-info"
  defp status_class(_), do: "badge-ghost"

  # ── Mount ────────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(30_000, self(), :refresh)
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic)
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @integrations_topic)
    end

    {:ok,
     socket
     |> assign_data()
     |> assign(
       active_tab: "mcp",
       current_path: "/plugins",
       selected_issue: nil,
       # Plugin action runner state
       selected_plugin: nil,
       selected_plugin_action: nil,
       plugin_action_params: "{}",
       plugin_action_result: nil,
       plugin_action_running: false,
       plugin_action_error: nil,
       # Integration event runner state
       selected_integration: nil,
       selected_integration_event: nil,
       integration_event_params: "{}",
       integration_event_result: nil,
       integration_event_running: false,
       integration_event_error: nil,
       integration_status_results: %{}
     )}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :integrations_tab}} = socket) do
    {:noreply, assign(socket, active_tab: "integrations", current_path: "/integrations")}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, current_path: "/plugins")}
  end

  # ── Tab / navigation events ──────────────────────────────────────────────────

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    socket =
      socket
      |> assign(
        active_tab: tab,
        selected_issue: nil,
        selected_plugin: nil,
        selected_plugin_action: nil,
        plugin_action_result: nil,
        plugin_action_error: nil,
        selected_integration: nil,
        selected_integration_event: nil,
        integration_event_result: nil,
        integration_event_error: nil
      )

    socket = if tab == "plane", do: load_plane_issues(socket), else: socket

    {:noreply, socket}
  end

  @impl true
  def handle_event("rescan", _params, socket) do
    ApmV5.PluginScanner.rescan()
    Process.sleep(300)
    {:noreply, assign_data(socket)}
  end

  # ── Plane PM events ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_issue", %{"id" => id}, socket) do
    issue =
      (socket.assigns[:plane_issues] || [])
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

  # ── Plugin action runner events ──────────────────────────────────────────────

  @impl true
  def handle_event("select_plugin", %{"name" => name}, socket) do
    plugin =
      socket.assigns.registered_plugins
      |> Enum.find(&(&1.name == name))

    {:noreply,
     assign(socket,
       selected_plugin: plugin,
       selected_plugin_action: nil,
       plugin_action_params: "{}",
       plugin_action_result: nil,
       plugin_action_error: nil
     )}
  end

  @impl true
  def handle_event("close_plugin_panel", _params, socket) do
    {:noreply,
     assign(socket,
       selected_plugin: nil,
       selected_plugin_action: nil,
       plugin_action_result: nil,
       plugin_action_error: nil
     )}
  end

  @impl true
  def handle_event("select_plugin_action", %{"action" => action}, socket) do
    # Pre-fill param skeleton from endpoint descriptor
    params_skeleton =
      case socket.assigns.selected_plugin do
        nil ->
          "{}"

        plugin ->
          ep = Enum.find(plugin.endpoints, &(&1.action == action))

          case ep do
            %{params: params_map} when map_size(params_map) > 0 ->
              skeleton =
                params_map
                |> Enum.map(fn {k, v} -> ~s|  "#{k}": ""  #{inspect(v)}| end)
                |> Enum.join(",\n")

              "{\n#{skeleton}\n}"

            _ ->
              "{}"
          end
      end

    {:noreply,
     assign(socket,
       selected_plugin_action: action,
       plugin_action_params: params_skeleton,
       plugin_action_result: nil,
       plugin_action_error: nil
     )}
  end

  @impl true
  def handle_event("update_plugin_params", %{"params" => raw}, socket) do
    {:noreply, assign(socket, plugin_action_params: raw)}
  end

  @impl true
  def handle_event("run_plugin_action", _params, socket) do
    %{selected_plugin: plugin, selected_plugin_action: action, plugin_action_params: raw} =
      socket.assigns

    if is_nil(plugin) or is_nil(action) do
      {:noreply, assign(socket, plugin_action_error: "Select a plugin and action first.")}
    else
      params =
        case Jason.decode(raw) do
          {:ok, map} -> map
          {:error, _} -> %{}
        end

      socket = assign(socket, plugin_action_running: true, plugin_action_error: nil, plugin_action_result: nil)

      Task.start(fn ->
        result = ApmV5.Plugins.PluginRegistry.call_plugin_action(plugin.name, action, params)
        send(self(), {:plugin_action_done, result})
      end)

      {:noreply, socket}
    end
  end

  # ── Integration event runner events ──────────────────────────────────────────

  @impl true
  def handle_event("select_integration", %{"name" => name}, socket) do
    integration =
      socket.assigns.integrations
      |> Enum.find(&(&1.name == name))

    {:noreply,
     assign(socket,
       selected_integration: integration,
       selected_integration_event: nil,
       integration_event_params: "{}",
       integration_event_result: nil,
       integration_event_error: nil
     )}
  end

  @impl true
  def handle_event("close_integration_panel", _params, socket) do
    {:noreply,
     assign(socket,
       selected_integration: nil,
       selected_integration_event: nil,
       integration_event_result: nil,
       integration_event_error: nil
     )}
  end

  @impl true
  def handle_event("select_integration_event", %{"event" => event}, socket) do
    params_skeleton =
      case socket.assigns.selected_integration do
        nil ->
          "{}"

        integration ->
          ep = Enum.find(integration.endpoints, &(&1.action == event))

          case ep do
            %{params: params_map} when is_map(params_map) and map_size(params_map) > 0 ->
              skeleton =
                params_map
                |> Enum.map(fn {k, v} -> ~s|  "#{k}": ""  #{inspect(v)}| end)
                |> Enum.join(",\n")

              "{\n#{skeleton}\n}"

            _ ->
              "{}"
          end
      end

    {:noreply,
     assign(socket,
       selected_integration_event: event,
       integration_event_params: params_skeleton,
       integration_event_result: nil,
       integration_event_error: nil
     )}
  end

  @impl true
  def handle_event("update_integration_params", %{"params" => raw}, socket) do
    {:noreply, assign(socket, integration_event_params: raw)}
  end

  @impl true
  def handle_event("run_integration_event", _params, socket) do
    %{
      selected_integration: integration,
      selected_integration_event: event,
      integration_event_params: raw
    } = socket.assigns

    if is_nil(integration) or is_nil(event) do
      {:noreply, assign(socket, integration_event_error: "Select an integration and event first.")}
    else
      params =
        case Jason.decode(raw) do
          {:ok, map} -> map
          {:error, _} -> %{}
        end

      socket = assign(socket, integration_event_running: true, integration_event_error: nil, integration_event_result: nil)

      name = integration.name

      Task.start(fn ->
        result = ApmV5.Integrations.IntegrationRegistry.call_integration_event(name, event, params)
        send(self(), {:integration_event_done, result})
      end)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("check_integration_status", %{"name" => name}, socket) do
    Task.start(fn ->
      status =
        case :ets.whereis(:integration_registry) do
          :undefined ->
            :disconnected

          _ ->
            case :ets.lookup(:integration_registry, name) do
              [{^name, {mod, _meta}}] ->
                try do
                  mod.status()
                rescue
                  _ -> :disconnected
                end

              [] ->
                :disconnected
            end
        end

      send(self(), {:integration_status_checked, name, status})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("reload_integrations", _params, socket) do
    ApmV5.Integrations.IntegrationRegistry.reload_defaults()
    Process.sleep(200)
    {:noreply, assign_integrations(socket)}
  end

  # ── Info (async results + PubSub) ────────────────────────────────────────────

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

  @impl true
  def handle_info({:plugin_action_done, result}, socket) do
    case result do
      {:ok, data} ->
        {:noreply,
         assign(socket,
           plugin_action_running: false,
           plugin_action_result: Jason.encode!(data, pretty: true),
           plugin_action_error: nil
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           plugin_action_running: false,
           plugin_action_result: nil,
           plugin_action_error: inspect(reason)
         )}
    end
  end

  @impl true
  def handle_info({:integration_event_done, result}, socket) do
    case result do
      {:ok, data} ->
        {:noreply,
         assign(socket,
           integration_event_running: false,
           integration_event_result: Jason.encode!(data, pretty: true),
           integration_event_error: nil
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           integration_event_running: false,
           integration_event_result: nil,
           integration_event_error: inspect(reason)
         )}
    end
  end

  @impl true
  def handle_info({:integration_status_checked, name, status}, socket) do
    results = Map.put(socket.assigns.integration_status_results, name, status)
    {:noreply, assign(socket, integration_status_results: results)}
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp assign_data(socket) do
    socket
    |> assign(
      mcp_servers: ApmV5.PluginScanner.get_mcp_servers(),
      plugins: ApmV5.PluginScanner.get_plugins(),
      page_title: "Plugins & Integrations"
    )
    |> assign_registered_plugins()
    |> assign_integrations()
  end

  defp assign_registered_plugins(socket) do
    assign(socket, registered_plugins: ApmV5.Plugins.PluginRegistry.list_plugins())
  end

  defp assign_integrations(socket) do
    integrations =
      if :ets.whereis(:integration_registry) != :undefined do
        ApmV5.Integrations.IntegrationRegistry.list_integrations()
      else
        []
      end

    assign(socket, integrations: integrations)
  end

  defp load_plane_issues(socket) do
    case ApmV5.Plugins.PluginRegistry.call_plugin_action("plane", "board_state", %{}) do
      {:ok, %{board: board, total: total}} ->
        assign(socket,
          plane_board: board,
          plane_issues: Enum.flat_map(board, & &1.issues),
          plane_total: total,
          plane_error: nil
        )

      {:error, {:not_found, _}} ->
        assign(socket, plane_board: [], plane_issues: [], plane_total: 0, plane_error: "Plane plugin not registered")

      {:error, reason} ->
        assign(socket, plane_board: [], plane_issues: [], plane_total: 0, plane_error: inspect(reason))
    end
  end

  # ── Render ────────────────────────────────────────────────────────────────────

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

      <div class="flex-1 flex flex-col overflow-hidden min-w-0">
        <%!-- Header --%>
        <header class="bg-base-200 border-b border-base-300 px-4 py-2 flex items-center justify-between flex-shrink-0">
          <div class="flex items-center gap-2">
            <h1 class="font-semibold text-sm">
              {if @current_path == "/integrations", do: "Integrations", else: "Plugins & MCP Servers"}
            </h1>
            <span class="badge badge-xs badge-outline">
              {if @current_path == "/integrations",
                do: "#{length(@integrations)} registered",
                else: "#{length(@mcp_servers)} MCP · #{length(@registered_plugins)} engine"}
            </span>
          </div>
          <div class="flex gap-2">
            <button :if={@current_path == "/integrations"} phx-click="reload_integrations" class="btn btn-xs btn-ghost gap-1">
              <.icon name="hero-arrow-path" class="size-3.5" /> Reload
            </button>
            <button phx-click="rescan" class="btn btn-xs btn-ghost gap-1">
              <.icon name="hero-magnifying-glass" class="size-3.5" /> Rescan
            </button>
          </div>
        </header>

        <%!-- Tab bar --%>
        <div class="border-b border-base-300 bg-base-200 px-4 flex gap-1 flex-shrink-0 overflow-x-auto">
          <button :if={@current_path != "/integrations"}
            phx-click="switch_tab" phx-value-tab="mcp"
            class={"tab tab-bordered tab-sm #{if @active_tab == "mcp", do: "tab-active", else: ""}"}>
            MCP ({length(@mcp_servers)})
          </button>
          <button :if={@current_path != "/integrations"}
            phx-click="switch_tab" phx-value-tab="discovered"
            class={"tab tab-bordered tab-sm #{if @active_tab == "discovered", do: "tab-active", else: ""}"}>
            Discovered ({length(@plugins)})
          </button>
          <button :if={@current_path != "/integrations"}
            phx-click="switch_tab" phx-value-tab="registered"
            class={"tab tab-bordered tab-sm #{if @active_tab == "registered", do: "tab-active", else: ""}"}>
            Engine Plugins ({length(@registered_plugins)})
          </button>
          <button :if={@current_path != "/integrations"}
            phx-click="switch_tab" phx-value-tab="plane"
            class={"tab tab-bordered tab-sm #{if @active_tab == "plane", do: "tab-active", else: ""}"}>
            Plane PM
          </button>
          <button :if={@current_path == "/integrations"}
            phx-click="switch_tab" phx-value-tab="integrations"
            class={"tab tab-bordered tab-sm #{if @active_tab == "integrations", do: "tab-active", else: ""}"}>
            Integrations ({length(@integrations)})
          </button>
        </div>

        <%!-- Content area --%>
        <div class="flex-1 overflow-hidden flex">
          <div class="flex-1 overflow-y-auto p-4 space-y-4">

            <%!-- MCP Servers --%>
            <div :if={@active_tab == "mcp"}>
              <div class="bg-base-200 rounded-lg p-4">
                <h2 class="text-sm font-semibold mb-3">MCP Servers ({length(@mcp_servers)})</h2>
                <div :if={@mcp_servers == []} class="text-xs text-base-content/40 py-6 text-center">
                  No MCP servers found in ~/.claude/settings.json
                </div>
                <div class="overflow-x-auto">
                  <table class="table table-xs w-full">
                    <thead><tr><th>Name</th><th>Type</th><th>Command</th><th>Args</th></tr></thead>
                    <tbody>
                      <tr :for={server <- @mcp_servers}>
                        <td class="font-medium">{server.name}</td>
                        <td><span class="badge badge-xs badge-outline">{server.type}</span></td>
                        <td class="font-mono text-xs">{server.command}</td>
                        <td class="font-mono text-xs text-base-content/60">{Enum.join(server.args, " ")}</td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>

            <%!-- Discovered Plugins --%>
            <div :if={@active_tab == "discovered"}>
              <div class="bg-base-200 rounded-lg p-4">
                <h2 class="text-sm font-semibold mb-3">Discovered Plugins ({length(@plugins)})</h2>
                <div :if={@plugins == []} class="text-xs text-base-content/40 py-6 text-center">
                  No plugins found in ~/.claude-plugin/ or ~/.claude/plugins/
                </div>
                <div class="overflow-x-auto">
                  <table class="table table-xs w-full">
                    <thead><tr><th>Name</th><th>Version</th><th>Description</th></tr></thead>
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

            <%!-- Engine Plugins (interactive) --%>
            <div :if={@active_tab == "registered"}>
              <div :if={@registered_plugins == []} class="bg-base-200 rounded-lg p-4 text-xs text-base-content/40 text-center py-8">
                No plugins registered in PluginRegistry yet.
              </div>
              <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
                <div
                  :for={plugin <- @registered_plugins}
                  phx-click="select_plugin"
                  phx-value-name={plugin.name}
                  class={[
                    "card card-compact shadow cursor-pointer transition-colors",
                    if(@selected_plugin && @selected_plugin.name == plugin.name,
                      do: "bg-primary/10 border border-primary/30",
                      else: "bg-base-200 hover:bg-base-100"
                    )
                  ]}
                >
                  <div class="card-body">
                    <div class="flex items-center justify-between">
                      <h3 class="font-semibold text-sm">{plugin.name}</h3>
                      <span class="badge badge-xs badge-primary">v{plugin.version}</span>
                    </div>
                    <p class="text-xs text-base-content/60 line-clamp-2">{plugin.description}</p>
                    <div class="flex flex-wrap gap-1 mt-1">
                      <span :for={ep <- plugin.endpoints} class="badge badge-xs badge-outline">
                        {ep.action}
                      </span>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Integrations (interactive) --%>
            <div :if={@active_tab == "integrations"}>
              <div :if={@integrations == []} class="bg-base-200 rounded-lg p-4 text-xs text-base-content/40 text-center py-8">
                No integrations registered. Check IntegrationRegistry startup.
              </div>
              <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                <div
                  :for={integration <- @integrations}
                  phx-click="select_integration"
                  phx-value-name={integration.name}
                  class={[
                    "card card-compact shadow cursor-pointer transition-colors",
                    if(@selected_integration && @selected_integration.name == integration.name,
                      do: "bg-secondary/10 border border-secondary/30",
                      else: "bg-base-200 hover:bg-base-100"
                    )
                  ]}
                >
                  <div class="card-body">
                    <div class="flex items-center justify-between gap-2">
                      <h3 class="font-semibold text-sm">{integration.name}</h3>
                      <div class="flex gap-1 flex-wrap justify-end">
                        <span class={"badge badge-xs #{protocol_class(integration.protocol)}"}>
                          {integration.protocol}
                        </span>
                        <span class={"badge badge-xs #{status_class(Map.get(@integration_status_results, integration.name, integration.status))}"}>
                          {Map.get(@integration_status_results, integration.name, integration.status)}
                        </span>
                        <span class="badge badge-xs">v{integration.version}</span>
                      </div>
                    </div>
                    <p class="text-xs text-base-content/60 line-clamp-2">{integration.description}</p>
                    <div class="flex items-center justify-between mt-1">
                      <div class="flex flex-wrap gap-1">
                        <span :for={ep <- integration.endpoints} class="badge badge-xs badge-outline">
                          {ep.action}
                        </span>
                      </div>
                      <button
                        phx-click="check_integration_status"
                        phx-value-name={integration.name}
                        phx-click-away-ignore
                        class="btn btn-xs btn-ghost shrink-0"
                        title="Refresh live status"
                      >
                        <.icon name="hero-signal" class="size-3" />
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Plane PM --%>
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
                Click Reload to fetch issues from Plane.
              </div>

              <div :if={@plane_board != []} class="flex gap-3 overflow-x-auto pb-2">
                <div :for={col <- @plane_board} class="flex-shrink-0 w-64 bg-base-200 rounded-lg p-3">
                  <div class="flex items-center justify-between mb-2">
                    <span class={"badge badge-sm #{state_class(col.state)}"}>{col.state}</span>
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

          <%!-- Plugin Action Runner Panel --%>
          <div :if={@active_tab == "registered" && @selected_plugin} class="w-80 xl:w-96 border-l border-base-300 bg-base-100 flex flex-col flex-shrink-0 overflow-hidden">
            <div class="flex items-center justify-between p-3 border-b border-base-300">
              <div>
                <p class="font-semibold text-sm">{@selected_plugin.name}</p>
                <p class="text-xs text-base-content/50">v{@selected_plugin.version}</p>
              </div>
              <button phx-click="close_plugin_panel" class="btn btn-ghost btn-xs btn-circle">
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <div class="flex-1 overflow-y-auto p-3 space-y-3">
              <%!-- Action selector --%>
              <div>
                <p class="text-xs font-semibold mb-2 text-base-content/60">Actions</p>
                <div class="space-y-1">
                  <button
                    :for={ep <- @selected_plugin.endpoints}
                    phx-click="select_plugin_action"
                    phx-value-action={ep.action}
                    class={[
                      "w-full text-left px-2 py-1.5 rounded text-xs transition-colors",
                      if(@selected_plugin_action == ep.action,
                        do: "bg-primary text-primary-content",
                        else: "hover:bg-base-200"
                      )
                    ]}
                  >
                    <span class="font-mono font-medium">{ep.action}</span>
                    <span class="block text-xs opacity-60 truncate">{ep.description}</span>
                  </button>
                </div>
              </div>

              <%!-- Params input --%>
              <div :if={@selected_plugin_action}>
                <p class="text-xs font-semibold mb-1 text-base-content/60">Params (JSON)</p>
                <textarea
                  phx-blur="update_plugin_params"
                  phx-value-params={@plugin_action_params}
                  class="textarea textarea-bordered textarea-xs w-full font-mono text-xs h-24 resize-y"
                  spellcheck="false"
                >{@plugin_action_params}</textarea>

                <button
                  phx-click="run_plugin_action"
                  disabled={@plugin_action_running}
                  class="btn btn-primary btn-xs w-full mt-2 gap-1"
                >
                  <span :if={@plugin_action_running} class="loading loading-spinner loading-xs" />
                  <.icon :if={!@plugin_action_running} name="hero-play" class="size-3" />
                  {if @plugin_action_running, do: "Running…", else: "Run"}
                </button>
              </div>

              <%!-- Error --%>
              <div :if={@plugin_action_error} class="alert alert-error py-2 text-xs">
                <.icon name="hero-exclamation-circle" class="size-3.5" />
                <span class="break-all">{@plugin_action_error}</span>
              </div>

              <%!-- Result --%>
              <div :if={@plugin_action_result}>
                <div class="flex items-center justify-between mb-1">
                  <p class="text-xs font-semibold text-success">Result</p>
                </div>
                <pre class="bg-base-200 rounded p-2 text-xs font-mono overflow-x-auto whitespace-pre-wrap break-all max-h-64 overflow-y-auto"><%= @plugin_action_result %></pre>
              </div>
            </div>
          </div>

          <%!-- Integration Event Runner Panel --%>
          <div :if={@active_tab == "integrations" && @selected_integration} class="w-80 xl:w-96 border-l border-base-300 bg-base-100 flex flex-col flex-shrink-0 overflow-hidden">
            <div class="flex items-center justify-between p-3 border-b border-base-300">
              <div>
                <p class="font-semibold text-sm">{@selected_integration.name}</p>
                <div class="flex gap-1 mt-0.5">
                  <span class={"badge badge-xs #{protocol_class(@selected_integration.protocol)}"}>
                    {@selected_integration.protocol}
                  </span>
                  <span class={"badge badge-xs #{status_class(Map.get(@integration_status_results, @selected_integration.name, @selected_integration.status))}"}>
                    {Map.get(@integration_status_results, @selected_integration.name, @selected_integration.status)}
                  </span>
                </div>
              </div>
              <div class="flex gap-1">
                <button
                  phx-click="check_integration_status"
                  phx-value-name={@selected_integration.name}
                  class="btn btn-ghost btn-xs btn-circle"
                  title="Refresh status"
                >
                  <.icon name="hero-signal" class="size-3.5" />
                </button>
                <button phx-click="close_integration_panel" class="btn btn-ghost btn-xs btn-circle">
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>
            </div>

            <div class="flex-1 overflow-y-auto p-3 space-y-3">
              <p class="text-xs text-base-content/60">{@selected_integration.description}</p>

              <%!-- Event selector --%>
              <div>
                <p class="text-xs font-semibold mb-2 text-base-content/60">Events</p>
                <div class="space-y-1">
                  <button
                    :for={ep <- @selected_integration.endpoints}
                    phx-click="select_integration_event"
                    phx-value-event={ep.action}
                    class={[
                      "w-full text-left px-2 py-1.5 rounded text-xs transition-colors",
                      if(@selected_integration_event == ep.action,
                        do: "bg-secondary text-secondary-content",
                        else: "hover:bg-base-200"
                      )
                    ]}
                  >
                    <span class="font-mono font-medium">{ep.action}</span>
                    <span class="block text-xs opacity-60 truncate">{ep.description}</span>
                  </button>
                </div>
              </div>

              <%!-- Params input --%>
              <div :if={@selected_integration_event}>
                <p class="text-xs font-semibold mb-1 text-base-content/60">Payload (JSON)</p>
                <textarea
                  phx-blur="update_integration_params"
                  phx-value-params={@integration_event_params}
                  class="textarea textarea-bordered textarea-xs w-full font-mono text-xs h-24 resize-y"
                  spellcheck="false"
                >{@integration_event_params}</textarea>

                <button
                  phx-click="run_integration_event"
                  disabled={@integration_event_running}
                  class="btn btn-secondary btn-xs w-full mt-2 gap-1"
                >
                  <span :if={@integration_event_running} class="loading loading-spinner loading-xs" />
                  <.icon :if={!@integration_event_running} name="hero-paper-airplane" class="size-3" />
                  {if @integration_event_running, do: "Sending…", else: "Send Event"}
                </button>
              </div>

              <%!-- Error --%>
              <div :if={@integration_event_error} class="alert alert-error py-2 text-xs">
                <.icon name="hero-exclamation-circle" class="size-3.5" />
                <span class="break-all">{@integration_event_error}</span>
              </div>

              <%!-- Result --%>
              <div :if={@integration_event_result}>
                <p class="text-xs font-semibold text-success mb-1">Response</p>
                <pre class="bg-base-200 rounded p-2 text-xs font-mono overflow-x-auto whitespace-pre-wrap break-all max-h-64 overflow-y-auto"><%= @integration_event_result %></pre>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Plane issue detail drawer --%>
      <div :if={@selected_issue} class="fixed inset-y-0 right-0 w-96 bg-base-100 shadow-2xl border-l border-base-300 z-50 flex flex-col">
        <div class="flex items-center justify-between p-4 border-b border-base-300">
          <span class="font-mono text-sm text-base-content/60">{@selected_issue.sequence_id}</span>
          <button phx-click="close_drawer" class="btn btn-ghost btn-xs btn-circle">
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <div class="flex-1 overflow-y-auto p-4 space-y-4">
          <h2 class="font-semibold text-sm">{@selected_issue.name}</h2>
          <div class="flex flex-wrap gap-2">
            <span class={"badge badge-sm #{state_class(@selected_issue.state_name)}"}>{@selected_issue.state_name}</span>
            <span :if={@selected_issue.priority && @selected_issue.priority != "none"} class={"badge badge-sm #{priority_class(@selected_issue.priority)}"}>
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
      <div :if={@selected_issue} phx-click="close_drawer" class="fixed inset-0 bg-black/30 z-40" />
    </div>
    <.wizard page="welcome" dom_id="ccem-wizard-welcome-plugins" />
    """
  end
end
