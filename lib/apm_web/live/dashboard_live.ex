defmodule ApmWeb.DashboardLive do
  @moduledoc """
  LiveView dashboard for CCEM APM.

  Ported from the Python APM v3 embedded HTML dashboard to Phoenix LiveView
  with daisyUI components. Displays agent fleet status, stats cards, notification
  toasts, sidebar navigation, and multi-project support.
  """

  use ApmWeb, :live_view

  import ApmWeb.Accessibility

  alias Apm.AgentRegistry
  alias Apm.ConfigLoader
  alias Apm.DashboardStore
  alias Apm.NamespaceResolver
  alias Apm.ProjectStore
  alias Apm.Ralph
  alias Apm.UpmStore
  alias Apm.PortManager
  alias Apm.GraphBuilder
  alias Apm.ChatStore
  alias Apm.LayoutStore
  alias Apm.WidgetConfigStore
  alias Apm.DashboardScopeEngine

  import ApmWeb.Components.GettingStartedShowcase

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:agents")
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:notifications")
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:config")
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:tasks")
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:commands")
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:upm")
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:ports")
      Phoenix.PubSub.subscribe(Apm.PubSub, "agentlock:authorization")
      Phoenix.PubSub.subscribe(Apm.PubSub, "agentlock:pending")

      # Subscribe to chat PubSub for live updates (initial scope: global)
      Phoenix.PubSub.subscribe(Apm.PubSub, ChatStore.topic("global"))

      # US-017: EventBus subscriptions for AG-UI integration
      Apm.AgUi.EventBus.subscribe("lifecycle:*")
      Apm.AgUi.EventBus.subscribe("state:*")
      Apm.AgUi.EventBus.subscribe("activity:*")
      Apm.AgUi.EventBus.subscribe("special:custom")

      # Widgetization Engine: subscribe to scope and session events (US-360)
      session_id = socket.id
      Phoenix.PubSub.subscribe(Apm.PubSub, "dashboard:scope:#{session_id}")
      Phoenix.PubSub.subscribe(Apm.PubSub, "dashboard:session:#{session_id}")
    end

    config = safe_get_config()
    projects = Map.get(config, "projects", [])
    active_project = Map.get(config, "active_project")

    agents = AgentRegistry.list_agents(active_project)
    notifications = AgentRegistry.get_notifications()
    uptime = calculate_uptime()
    tasks = ProjectStore.get_tasks(active_project || "_global")
    commands = ProjectStore.get_commands(active_project || "_global")
    ralph_data = load_ralph_for_project(active_project, config)
    session_count = live_session_count(config)
    # Batch-fetch cross-project data from DashboardData snapshot cache (US-603)
    # Single ETS read replaces 6 sequential GenServer.calls on cold mount.
    snap = Apm.DashboardData.snapshot()
    upm_status = snap.upm_status || UpmStore.get_status()
    project_configs = snap.project_configs
    port_clashes = snap.port_clashes
    port_ranges = snap.port_ranges

    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> assign(:projects, projects)
      |> assign(:active_project, active_project)
      |> assign(:project_cats, categorize_projects(projects, active_project))
      |> assign(:show_other_projects, false)
      |> assign(:agents, agents)
      |> assign(:notifications, notifications)
      |> assign(:notification_channel_filter, nil)
      |> assign(:notification_source_filter, nil)
      |> assign(:uptime, uptime)
      |> assign(:agent_count, length(agents))
      |> assign(:active_count, Enum.count(agents, &(&1.status == "active")))
      |> assign(:idle_count, Enum.count(agents, &(&1.status == "idle")))
      |> assign(:error_count, Enum.count(agents, &(&1.status == "error")))
      |> assign(:session_count, session_count)
      |> assign(:active_nav, :dashboard)
      |> assign(:active_tab, :inspector)
      |> assign(:selected_agent, nil)
      |> assign(:tasks, tasks)
      |> assign(:commands, commands)
      |> assign(:ralph_data, ralph_data)
      |> assign(:active_skill_count, skill_count())
      |> assign(:upm_status, upm_status)
      |> assign(:project_configs, project_configs)
      |> assign(:port_clashes, port_clashes)
      |> assign(:port_ranges, port_ranges)
      |> assign(:port_remediation, nil)
      |> assign(:graph_expanded, false)
      |> assign(:graph_view, :graph)
      |> assign(:show_anon, false)
      |> assign(:collapsed_projects, MapSet.new())
      |> assign(:list_expanded_nodes, MapSet.new(["root"]))
      |> assign(:hierarchy, nil)
      |> assign(:chat_scope, "global")
      |> assign(:chat_messages, [])
      |> assign(:chat_input, "")
      |> assign(:show_showcase, true)
      |> assign(:saved_layouts, snap.saved_layouts)
      |> assign(:agentlock_pending, safe_list_pending())
      |> assign(:auth_dismissed, false)
      |> assign(:saved_presets, snap.saved_presets)
      # Global filter bar state (Splunk/ELK-style)
      |> assign(:filter_status, nil)
      |> assign(:filter_namespace, nil)
      |> assign(:filter_agent_type, nil)
      |> assign(:filter_query, "")
      # Widgetization Engine assigns (US-360, US-367)
      |> assign(:widget_scope_type, :global)
      |> assign(:widget_scope_value, nil)
      |> assign(:widget_pinned_id, nil)
      |> assign(:widget_edit_panel_id, nil)
      |> assign(:widget_session_configs, load_widget_session_configs(socket))
      |> assign(:widget_layout_placements, load_widget_layout(socket))
      |> assign(:inspector_collapsed, false)
      # DS layout shell assigns (CP-175)
      |> assign(:sidebar_collapsed, false)
      |> assign(:inspector_open, false)
      |> assign(:inspector_mode, "copilot")
      |> push_graph_data(agents)
      |> ApmWeb.Components.SidebarNav.assign_sidebar_nav_data()

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"agent_id" => agent_id}, _uri, socket) do
    agent = AgentRegistry.get_agent(agent_id)

    socket =
      if agent do
        scope = "agent:#{agent_id}"

        if connected?(socket) do
          Phoenix.PubSub.unsubscribe(Apm.PubSub, ChatStore.topic(socket.assigns.chat_scope))
          Phoenix.PubSub.subscribe(Apm.PubSub, ChatStore.topic(scope))
        end

        messages = ChatStore.list_messages(scope, 50)

        socket
        |> assign(:active_tab, :inspector)
        |> assign(:selected_agent, agent)
        |> assign(:chat_scope, scope)
        |> assign(:chat_messages, messages)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # ── Widgetization Engine helpers (US-367) ────────────────────────────────────

  defp load_widget_session_configs(socket) do
    try do
      WidgetConfigStore.get_all_configs(socket.id)
    rescue
      _ -> %{}
    end
  end

  defp load_widget_layout(socket) do
    try do
      case LayoutStore.get_user_layout(socket.id) do
        %{placements: placements} -> placements
        _ ->
          preset = LayoutStore.get_preset("default")
          if preset, do: preset.placements, else: []
      end
    rescue
      _ -> []
    end
  end

  defp filter_by_status(agents, nil), do: agents
  defp filter_by_status(agents, ""), do: agents
  defp filter_by_status(agents, status), do: Enum.filter(agents, &(&1.status == status))

  defp filter_by_namespace(agents, nil), do: agents
  defp filter_by_namespace(agents, ""), do: agents
  defp filter_by_namespace(agents, ns), do: Enum.filter(agents, &(&1[:namespace] == ns))

  defp filter_by_agent_type(agents, nil), do: agents
  defp filter_by_agent_type(agents, ""), do: agents
  defp filter_by_agent_type(agents, t), do: Enum.filter(agents, &((&1[:agent_type] || "individual") == t))

  defp filter_by_query(agents, nil), do: agents
  defp filter_by_query(agents, ""), do: agents
  defp filter_by_query(agents, q) do
    q = String.downcase(q)
    Enum.filter(agents, fn a ->
      String.contains?(String.downcase(a.name || ""), q) ||
      String.contains?(String.downcase(a.id || ""), q) ||
      String.contains?(String.downcase(a[:namespace] || ""), q)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout
      sidebar_collapsed={@sidebar_collapsed}
      inspector_open={@inspector_open}
      inspector_mode={@inspector_mode}
    >
      <%!-- Sidebar slot --%>
      <:sidebar>
        <.sidebar_nav
          current_path="/"
          notification_count={length(@notifications)}
          skill_count={@active_skill_count}
          plugins={@plugins}
          integrations={@integrations}
        />
      </:sidebar>

      <%!-- Top bar slot --%>
      <:topbar>
        <.top_bar
          project_name={@active_project || "CCEM APM"}
          project_list={Enum.map(@projects, fn p -> {p["name"], p["name"]} end)}
          active_project_id={@active_project}
          session_count={@session_count}
          current_user="Jeremiah Pegues"
          on_project_change="switch_project"
        />
      </:topbar>

      <%!-- Main content slot --%>
      <:main>
        <%!-- 6-up metric stat tiles --%>
        <.live_region id="agent-status-summary" politeness="polite">
          <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(120px, 1fr)); gap: 12px; margin-bottom: 16px;">
            <.card padded={true}>
              <.stat_tile label="Agents" value={to_string(@agent_count)} delta_direction="flat" />
            </.card>
            <.card padded={true}>
              <.stat_tile
                label="Active"
                value={to_string(@active_count)}
                delta={if @active_count > 0, do: "+#{@active_count}", else: nil}
                delta_direction="up"
              />
            </.card>
            <.card padded={true}>
              <.stat_tile label="Idle" value={to_string(@idle_count)} delta_direction="flat" />
            </.card>
            <.card padded={true}>
              <.stat_tile
                label="Errors"
                value={to_string(@error_count)}
                delta={if @error_count > 0, do: to_string(@error_count), else: nil}
                delta_direction={if @error_count > 0, do: "down", else: "flat"}
              />
            </.card>
            <.card padded={true}>
              <.stat_tile label="Sessions" value={to_string(@session_count)} delta_direction="flat" />
            </.card>
            <.card padded={true}>
              <.stat_tile
                label="Notifs"
                value={to_string(length(@notifications))}
                delta_direction="flat"
              />
            </.card>
          </div>
        </.live_region>

        <%!-- AgentLock pending approval banner --%>
        <%= if @agentlock_pending != [] && !@auth_dismissed do %>
          <% [top | _rest] = @agentlock_pending %>
          <% label = NamespaceResolver.gate_label(top.request_id, top.tool_name) %>
          <% agent_lbl = NamespaceResolver.agent_label(top.agent_id) %>
          <div
            id="dashboard-agentlock-toast"
            style="display: flex; align-items: center; justify-content: space-between; border: 1px solid color-mix(in srgb, var(--ccem-warn) 40%, transparent); background: color-mix(in srgb, var(--ccem-warn) 8%, transparent); border-radius: 8px; padding: 8px 12px; margin-bottom: 12px; font-size: 12px; gap: 8px;"
            role="alert"
            aria-live="assertive"
          >
            <div style="display: flex; align-items: center; gap: 8px; min-width: 0; flex: 1;">
              <.badge tone="warning" dot>Approval Required</.badge>
              <span style="font-family: var(--ccem-font-mono); color: var(--ccem-warn); font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                <%= label %>
              </span>
              <span style="color: var(--ccem-fg-dim);">&middot;</span>
              <span style="color: var(--ccem-fg); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                <%= agent_lbl %>
              </span>
              <span style="color: var(--ccem-fg-dim);">&middot;</span>
              <span style="color: var(--ccem-fg-muted);"><%= top.risk_level %> risk</span>
              <div
                phx-hook="CountdownTimer"
                id={"dashboard-toast-cd-#{top.request_id}"}
                data-seconds="20"
                style="font-family: var(--ccem-font-mono); font-size: 10px; color: color-mix(in srgb, var(--ccem-warn) 60%, transparent); flex-shrink: 0;"
              >
                <span data-countdown-display>20s</span>
              </div>
              <%= if length(@agentlock_pending) > 1 do %>
                <.badge tone="warning" square><%= length(@agentlock_pending) %></.badge>
              <% end %>
            </div>
            <div style="display: flex; align-items: center; gap: 6px; flex-shrink: 0;">
              <.btn variant="primary" size="xs" phx-click="approve_gate" phx-value-id={top.request_id}>
                Approve
              </.btn>
              <.btn variant="destructive" size="xs" phx-click="deny_gate" phx-value-id={top.request_id}>
                Deny
              </.btn>
              <.link navigate="/authorization">
                <.btn variant="ghost" size="xs" aria-label="View in Authorization">&#8599;</.btn>
              </.link>
              <.btn variant="icon" size="xs" phx-click="dismiss_auth" aria-label="Dismiss">
                &#x2715;
              </.btn>
            </div>
          </div>
        <% end %>

        <%!-- UPM Execution Panel --%>
        <div :if={@upm_status.active} style="margin-bottom: 12px;">
          <.card padded={false}>
            <div style="padding: 12px;">
              <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 8px;">
                <span style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-dim);">
                  UPM Execution
                </span>
                <.badge tone={upm_tone(@upm_status.session.status)}>
                  {@upm_status.session.status}
                </.badge>
              </div>
              <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 8px; font-size: 12px; color: var(--ccem-fg-muted);">
                <span>Wave {@upm_status.session.current_wave}/{@upm_status.session.total_waves}</span>
                <div style="flex: 1; background: var(--ccem-bg-2); border-radius: 999px; height: 4px; overflow: hidden;">
                  <div style={"width: #{if @upm_status.session.total_waves > 0, do: trunc(@upm_status.session.current_wave / @upm_status.session.total_waves * 100), else: 0}%; background: var(--ccem-iris); height: 4px; border-radius: 999px; transition: width 300ms ease;"}>
                  </div>
                </div>
                <span style="font-size: 10px; color: var(--ccem-fg-faint);">
                  {upm_story_summary(@upm_status.session.stories)}
                </span>
              </div>
            </div>
          </.card>
        </div>

        <%!-- Formation Dependency Graph --%>
        <div style="margin-bottom: 12px;">
          <.card padded={false}>
            <div style="padding: 12px 12px 0 12px; display: flex; align-items: center; justify-content: space-between;">
              <span style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-dim);">
                Formation Graph
              </span>
              <div style="display: flex; align-items: center; gap: 6px;">
                <.btn variant="ghost" size="xs" phx-click="set_graph_view" phx-value-view="graph">
                  Graph
                </.btn>
                <.btn variant="ghost" size="xs" phx-click="set_graph_view" phx-value-view="list">
                  List
                </.btn>
                <.btn
                  variant="ghost"
                  size="xs"
                  phx-click="toggle_graph"
                  aria-label={if @graph_expanded, do: "Collapse", else: "Expand"}
                >
                  {if @graph_expanded, do: "⤢", else: "⤡"}
                </.btn>
              </div>
            </div>
            <%= if @graph_view == :graph do %>
              <div
                id="dep-graph"
                style={"width: 100%; border-radius: 0 0 8px 8px; overflow: hidden; background: #151b28; #{if @graph_expanded, do: "height: calc(100vh - 160px);", else: "height: 380px;"}"}
                phx-hook="DependencyGraph"
                phx-update="ignore"
              >
              </div>
            <% else %>
              <div style="padding: 0 12px 12px; overflow-y: auto; max-height: 380px;">
                <%= if @hierarchy do %>
                  <.tree_node
                    node={@hierarchy}
                    depth={0}
                    expanded={@list_expanded_nodes}
                    selected_id={@selected_agent &&
                      (@selected_agent[:id] || @selected_agent["id"])}
                  />
                <% else %>
                  <div style="text-align: center; font-size: 12px; color: var(--ccem-fg-faint); padding: 48px 0;">
                    No agents registered. POST to
                    <code style="font-family: var(--ccem-font-mono);">/api/register</code>
                    to add agents.
                  </div>
                <% end %>
              </div>
            <% end %>
          </.card>
        </div>

        <%!-- Agent Fleet Table --%>
        <div style="margin-bottom: 12px;">
          <.card padded={false}>
            <div style="padding: 12px 12px 8px 12px; display: flex; align-items: center; justify-content: space-between;">
              <span style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-dim);">
                Fleet
              </span>
              <div style="display: flex; align-items: center; gap: 6px;">
                <input
                  type="text"
                  placeholder="Search..."
                  value={@filter_query}
                  phx-keyup="update_filter_query"
                  phx-debounce="200"
                  style="height: 24px; padding: 0 8px; font-size: 11px; background: var(--ccem-bg-2); border: 1px solid var(--ccem-line); border-radius: 4px; color: var(--ccem-fg); min-width: 120px;"
                />
                <.badge :if={@filter_status} tone="accent">{@filter_status}</.badge>
                <.btn
                  :if={@filter_status || @filter_namespace || @filter_agent_type || @filter_query != ""}
                  variant="ghost"
                  size="xs"
                  phx-click="clear_filters"
                >
                  Clear
                </.btn>
              </div>
            </div>
            <ApmWeb.Components.AgentPanel.agent_fleet
              agents={@agents}
              filter_status={@filter_status}
              filter_namespace={@filter_namespace}
              filter_agent_type={@filter_agent_type}
              filter_query={@filter_query}
            />
          </.card>
        </div>

        <%!-- Widgetization Engine (CP-93–CP-106) --%>
        <div style="border-top: 1px solid var(--ccem-line-subtle); padding-top: 16px;">
          <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px;">
            <span style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-faint);">
              Widgets
            </span>
          </div>
          <.live_component
            module={ApmWeb.Live.DashboardGridComponent}
            id="dashboard-grid"
            placements={@widget_layout_placements}
            widget_pinned_id={@widget_pinned_id}
            widget_edit_panel_id={@widget_edit_panel_id}
            widget_scope_type={@widget_scope_type}
            widget_scope_value={@widget_scope_value}
            session_configs={@widget_session_configs}
          >
            <:widget :let={slot_assigns}>
              <.live_component
                module={ApmWeb.Live.WidgetContainerComponent}
                id={"widget-container-#{slot_assigns.widget.id}"}
                widget={slot_assigns.widget}
                current_config={slot_assigns.config}
                is_pinned={slot_assigns.is_pinned}
              >
                <:body></:body>
              </.live_component>
            </:widget>
          </.live_component>
          <%= if @widget_edit_panel_id do %>
            <% edit_widget = Apm.WidgetRegistry.get_widget(@widget_edit_panel_id) %>
            <.live_component
              :if={edit_widget}
              module={ApmWeb.Live.WidgetEditPanelComponent}
              id={"edit-panel-#{@widget_edit_panel_id}"}
              widget={edit_widget}
              current_config={Map.get(@widget_session_configs, @widget_edit_panel_id, %{})}
              is_open={true}
            />
          <% end %>
        </div>

        <%!-- Getting Started Showcase --%>
        <.showcase show={@show_showcase} />
      </:main>

      <%!-- Inspector slot --%>
      <:inspector>
        <.inspector_panel open={@inspector_open} mode={@inspector_mode} on_close="toggle_inspector">
          <:copilot>
            <ApmWeb.Components.ScopeBreadcrumb.breadcrumb scope={@chat_scope} />
            <ApmWeb.Components.AgentControlPanel.control_bar
              selected_agent={@selected_agent}
              agent_status={if @selected_agent, do: @selected_agent.status, else: "unknown"}
            />
            <div
              :if={is_nil(@selected_agent)}
              style="text-align: center; color: var(--ccem-fg-faint); padding: 32px 0; font-size: 12px;"
            >
              Click an agent or graph node to inspect
            </div>
            <div :if={@selected_agent} style="display: flex; flex-direction: column; gap: 12px;">
              <.card padded={true}>
                <div style="font-size: 12px; display: flex; flex-direction: column; gap: 4px;">
                  <div style="display: flex; justify-content: space-between;">
                    <span style="color: var(--ccem-fg-dim);">ID</span>
                    <span style="font-family: var(--ccem-font-mono); font-size: 11px; color: var(--ccem-fg);">
                      {@selected_agent.id}
                    </span>
                  </div>
                  <div style="display: flex; justify-content: space-between;">
                    <span style="color: var(--ccem-fg-dim);">Status</span>
                    <.badge tone={agent_status_tone(@selected_agent.status)}>
                      {@selected_agent.status}
                    </.badge>
                  </div>
                  <div style="display: flex; justify-content: space-between;">
                    <span style="color: var(--ccem-fg-dim);">Type</span>
                    <.badge tone="neutral">{@selected_agent[:agent_type] || "individual"}</.badge>
                  </div>
                </div>
              </.card>
            </div>
          </:copilot>
          <:selection>
            <div
              :if={is_nil(@selected_agent)}
              style="text-align: center; color: var(--ccem-fg-faint); padding: 32px 0; font-size: 12px;"
            >
              No selection
            </div>
            <div :if={@selected_agent} style="display: flex; flex-direction: column; gap: 8px;">
              <.agent_card
                agent_id={@selected_agent.id}
                name={@selected_agent.name || @selected_agent.id}
                role={@selected_agent[:agent_type] || "individual"}
                status={@selected_agent.status}
              />
              <div style="font-size: 12px; color: var(--ccem-fg-dim);">
                <div>Namespace: {@selected_agent[:namespace] || "—"}</div>
                <div>Last seen: {format_last_seen(@selected_agent[:last_seen])}</div>
              </div>
            </div>
          </:selection>
          <:filters>
            <div style="display: flex; flex-direction: column; gap: 8px;">
              <div style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-dim); margin-bottom: 4px;">
                Status
              </div>
              <div style="display: flex; flex-wrap: wrap; gap: 4px;">
                <.btn
                  :for={s <- ["active", "idle", "error", "discovered", "completed"]}
                  variant={if @filter_status == s, do: "primary", else: "ghost"}
                  size="xs"
                  phx-click="set_filter"
                  phx-value-field="status"
                  phx-value-value={s}
                >
                  {s}
                </.btn>
              </div>
              <div style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-dim); margin-top: 8px; margin-bottom: 4px;">
                Type
              </div>
              <div style="display: flex; flex-wrap: wrap; gap: 4px;">
                <.btn
                  :for={t <- ["individual", "squadron", "swarm", "orchestrator"]}
                  variant={if @filter_agent_type == t, do: "primary", else: "ghost"}
                  size="xs"
                  phx-click="set_filter"
                  phx-value-field="agent_type"
                  phx-value-value={t}
                >
                  {t}
                </.btn>
              </div>
              <.btn
                :if={@filter_status || @filter_namespace || @filter_agent_type ||
                  @filter_query != ""}
                variant="destructive"
                size="sm"
                phx-click="clear_filters"
                style="margin-top: 8px;"
              >
                Clear All Filters
              </.btn>
            </div>
          </:filters>
        </.inspector_panel>
      </:inspector>
    </.page_layout>
    """
  end


  # --- Event Handlers ---

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  def handle_event("toggle_inspector", _params, socket) do
    {:noreply,
     socket
     |> assign(:inspector_collapsed, !socket.assigns.inspector_collapsed)
     |> assign(:inspector_open, !socket.assigns.inspector_open)}
  end

  # DS layout shell events (CP-175)
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_collapsed, !socket.assigns.sidebar_collapsed)}
  end

  def handle_event("inspector_mode", %{"mode" => mode}, socket)
      when mode in ["selection", "copilot", "filters"] do
    {:noreply, assign(socket, :inspector_mode, mode)}
  end

  def handle_event("inspector_mode", _params, socket), do: {:noreply, socket}

  # Chat events
  def handle_event("chat:send", %{"content" => content}, socket) when content != "" do
    scope = socket.assigns.chat_scope
    metadata = case socket.assigns.selected_agent do
      nil -> %{}
      agent -> %{"agent_id" => agent.id}
    end

    case ChatStore.send_message(scope, content, metadata) do
      {:ok, _msg} ->
        messages = ChatStore.list_messages(scope, 50)
        {:noreply, socket |> assign(:chat_messages, messages) |> assign(:chat_input, "")}
    end
  end

  def handle_event("chat:send", _params, socket), do: {:noreply, socket}
  def handle_event("chat:input", %{"content" => val}, socket), do: {:noreply, assign(socket, :chat_input, val)}

  # Scope navigation — re-subscribe to new chat scope PubSub topic
  def handle_event("scope:set", %{"scope" => scope}, socket) do
    old_scope = socket.assigns.chat_scope

    if connected?(socket) && old_scope != scope do
      Phoenix.PubSub.unsubscribe(Apm.PubSub, ChatStore.topic(old_scope))
      Phoenix.PubSub.subscribe(Apm.PubSub, ChatStore.topic(scope))
    end

    messages = ChatStore.list_messages(scope, 50)
    {:noreply, socket |> assign(:chat_scope, scope) |> assign(:chat_messages, messages)}
  end

  # ── Widgetization Engine — widget edit, pin, config, and layout events (US-367) ──

  def handle_event("widget_edit_open", %{"widget_id" => widget_id}, socket) do
    {:noreply, assign(socket, :widget_edit_panel_id, widget_id)}
  end

  def handle_event("widget_edit_close", _params, socket) do
    {:noreply, assign(socket, :widget_edit_panel_id, nil)}
  end

  def handle_event("widget_config_saved", %{"widget_id" => widget_id, "config" => config}, socket)
      when is_binary(widget_id) and is_map(config) do
    session_id = socket.id
    WidgetConfigStore.put_config(session_id, widget_id, config)
    updated_configs = WidgetConfigStore.get_all_configs(session_id)
    {:noreply,
     socket
     |> assign(:widget_edit_panel_id, nil)
     |> assign(:widget_session_configs, updated_configs)}
  end

  def handle_event("widget_pin_toggle", %{"widget_id" => widget_id}, socket) do
    session_id = socket.id
    current_pinned = socket.assigns.widget_pinned_id

    if current_pinned == widget_id do
      DashboardScopeEngine.unpin(session_id)
    else
      DashboardScopeEngine.pin_scope_source(session_id, widget_id)
    end

    {:noreply, socket}
  end

  def handle_event("widget_scope_select", %{"scope_type" => scope_type_str, "scope_value" => scope_value}, socket) do
    session_id = socket.id
    scope_type = String.to_existing_atom(scope_type_str)
    DashboardScopeEngine.broadcast_scope(session_id, scope_type, scope_value)
    {:noreply, socket}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("layout_reorder", %{"order" => widget_order}, socket) when is_list(widget_order) do
    session_id = socket.id
    current_layout = LayoutStore.get_user_layout(session_id) || %{}
    LayoutStore.save_user_layout(session_id, Map.put(current_layout, :widget_order, widget_order))
    {:noreply, socket}
  end

  def handle_event("layout_preset_select", %{"preset_id" => preset_id}, socket) do
    case LayoutStore.get_preset(preset_id) do
      nil ->
        {:noreply, socket}
      preset ->
        {:noreply, assign(socket, :widget_layout_placements, preset.placements)}
    end
  end

  # Agent control events — call registry directly (same server)
  def handle_event("agent:control", %{"action" => action, "id" => id}, socket) do
    new_status = case action do
      "connect" -> "active"
      "disconnect" -> "offline"
      "restart" -> "active"
      "stop" -> "offline"
      "pause" -> "idle"
      "resume" -> "active"
      _ -> nil
    end

    if new_status do
      AgentRegistry.update_agent(id, %{status: new_status})
    end

    {:noreply, socket}
  rescue
    _ -> {:noreply, socket}
  end

  def handle_event("formation:control", %{"action" => action, "id" => formation_id}, socket) do
    agents = AgentRegistry.list_agents()
    |> Enum.filter(fn a -> (a[:formation_id] || a["formation_id"]) == formation_id end)

    new_status = case action do
      "restart" -> "active"
      "stop" -> "offline"
      _ -> nil
    end

    if new_status do
      Enum.each(agents, fn a ->
        AgentRegistry.update_agent(a[:id] || a["id"], %{status: new_status})
      end)
    end

    {:noreply, socket}
  rescue
    _ -> {:noreply, socket}
  end

  # Showcase events
  # US-003: AgentLock pending decision approve/deny from dashboard floating banner
  def handle_event("approve_gate", %{"id" => request_id}, socket) do
    Apm.Auth.PendingDecisions.decide(request_id, :approve)
    pending = Enum.reject(socket.assigns.agentlock_pending, &(&1.request_id == request_id))
    {:noreply, assign(socket, :agentlock_pending, pending)}
  end

  def handle_event("deny_gate", %{"id" => request_id}, socket) do
    Apm.Auth.PendingDecisions.decide(request_id, :deny)
    pending = Enum.reject(socket.assigns.agentlock_pending, &(&1.request_id == request_id))
    {:noreply, assign(socket, :agentlock_pending, pending)}
  end

  def handle_event("dismiss_auth", _params, socket) do
    {:noreply, assign(socket, :auth_dismissed, true)}
  end

  def handle_event("showcase:dismiss", _params, socket) do
    {:noreply, assign(socket, :show_showcase, false)}
  end

  def handle_event("showcase:show", _params, socket) do
    socket =
      socket
      |> assign(:show_showcase, true)
      |> push_event("showcase:reshow", %{})

    {:noreply, socket}
  end

  def handle_event("set_graph_view", %{"view" => view}, socket) do
    socket = assign(socket, :graph_view, String.to_existing_atom(view))

    # When switching to list view, expand ancestors of selected agent
    socket =
      if view == "list" do
        selected = socket.assigns[:selected_agent]
        agent_id = selected && (selected[:id] || selected["id"])
        hierarchy = socket.assigns[:hierarchy]
        expanded = socket.assigns[:list_expanded_nodes] || MapSet.new(["root"])

        updated =
          case agent_id && hierarchy && find_ancestor_path(hierarchy, agent_id) do
            nil -> expanded
            path -> Enum.reduce(path, expanded, &MapSet.put(&2, &1))
          end

        assign(socket, :list_expanded_nodes, updated)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("toggle_graph", _params, socket) do
    expanded = !socket.assigns.graph_expanded
    socket =
      socket
      |> assign(:graph_expanded, expanded)
      |> push_event("graph_resize", %{expanded: expanded})
    {:noreply, socket}
  end

  def handle_event("toggle_project_collapse", %{"project" => project_name}, socket) do
    collapsed = socket.assigns.collapsed_projects

    updated =
      if MapSet.member?(collapsed, project_name),
        do: MapSet.delete(collapsed, project_name),
        else: MapSet.put(collapsed, project_name)

    socket =
      socket
      |> assign(:collapsed_projects, updated)
      |> push_event("graph:collapsed_projects", %{projects: MapSet.to_list(updated)})

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_other_projects", _params, socket) do
    {:noreply, assign(socket, :show_other_projects, !socket.assigns.show_other_projects)}
  end

  def handle_event("switch_project", %{"project" => ""}, socket) do
    config = safe_get_config()
    agents = AgentRegistry.list_agents()
    tasks = ProjectStore.get_tasks("_global")
    commands = ProjectStore.get_commands("_global")
    ralph_data = load_ralph_for_project(nil, config)

    socket =
      socket
      |> assign(:active_project, nil)
      |> assign(:agents, agents)
      |> assign(:tasks, tasks)
      |> assign(:commands, commands)
      |> assign(:ralph_data, ralph_data)
      |> update_agent_counts(agents)
      |> push_graph_data(agents)

    {:noreply, socket}
  end

  def handle_event("switch_project", %{"project" => project_name}, socket) do
    config = safe_get_config()
    agents = AgentRegistry.list_agents(project_name)
    tasks = ProjectStore.get_tasks(project_name)
    commands = ProjectStore.get_commands(project_name)
    ralph_data = load_ralph_for_project(project_name, config)

    socket =
      socket
      |> assign(:active_project, project_name)
      |> assign(:agents, agents)
      |> assign(:tasks, tasks)
      |> assign(:commands, commands)
      |> assign(:ralph_data, ralph_data)
      |> update_agent_counts(agents)
      |> push_graph_data(agents)

    {:noreply, socket}
  end

  def handle_event("clear_notifications", _params, socket) do
    AgentRegistry.clear_notifications()
    {:noreply, assign(socket, :notifications, [])}
  end

  def handle_event("mark_all_read", _params, socket) do
    AgentRegistry.mark_all_notifications_read()
    notifications = Enum.map(socket.assigns.notifications, &Map.put(&1, :read, true))
    {:noreply, assign(socket, :notifications, notifications)}
  end

  def handle_event("dismiss_notification", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    AgentRegistry.dismiss_notification(id)
    notifications = Enum.reject(socket.assigns.notifications, &(&1[:id] == id))
    {:noreply, assign(socket, :notifications, notifications)}
  end

  def handle_event("filter_notifications_by_channel", %{"channel" => channel}, socket) do
    filter = if channel == "", do: nil, else: channel
    {:noreply, assign(socket, :notification_channel_filter, filter)}
  end

  def handle_event("filter_notifications_by_source", %{"source" => source}, socket) do
    filter = if source == "", do: nil, else: source
    {:noreply, assign(socket, :notification_source_filter, filter)}
  end

  def handle_event("select_agent", %{"agent_id" => agent_id}, socket) do
    agent = AgentRegistry.get_agent(agent_id)

    socket =
      if agent do
        # Expand ancestor path in the list view so the agent is visible
        hierarchy = socket.assigns[:hierarchy]
        expanded = socket.assigns[:list_expanded_nodes] || MapSet.new(["root"])

        updated_expanded =
          case hierarchy && find_ancestor_path(hierarchy, agent_id) do
            nil -> expanded
            path -> Enum.reduce(path, expanded, &MapSet.put(&2, &1))
          end

        scope = "agent:#{agent_id}"
        old_scope = socket.assigns.chat_scope
        messages = ChatStore.list_messages(scope, 50)

        # Re-subscribe to new chat scope PubSub topic
        if connected?(socket) && old_scope != scope do
          Phoenix.PubSub.unsubscribe(Apm.PubSub, ChatStore.topic(old_scope))
          Phoenix.PubSub.subscribe(Apm.PubSub, ChatStore.topic(scope))
        end

        socket
        |> assign(:active_tab, :inspector)
        |> assign(:selected_agent, agent)
        |> assign(:list_expanded_nodes, updated_expanded)
        |> assign(:chat_scope, scope)
        |> assign(:chat_messages, messages)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("toggle_list_node", %{"node_id" => node_id}, socket) do
    expanded = socket.assigns.list_expanded_nodes

    updated =
      if MapSet.member?(expanded, node_id),
        do: MapSet.delete(expanded, node_id),
        else: MapSet.put(expanded, node_id)

    {:noreply, assign(socket, :list_expanded_nodes, updated)}
  end

  # --- Filter Event Handlers ---

  def handle_event("set_filter", %{"field" => "status", "value" => val}, socket) do
    val = if val == "", do: nil, else: val
    socket = assign(socket, :filter_status, val) |> push_filtered_graph()
    {:noreply, socket}
  end

  def handle_event("set_filter", %{"field" => "agent_type", "value" => val}, socket) do
    val = if val == "", do: nil, else: val
    socket = assign(socket, :filter_agent_type, val) |> push_filtered_graph()
    {:noreply, socket}
  end

  def handle_event("set_filter", %{"field" => "namespace", "value" => val}, socket) do
    val = if val == "", do: nil, else: val
    socket = assign(socket, :filter_namespace, val) |> push_filtered_graph()
    {:noreply, socket}
  end

  def handle_event("update_filter_query", %{"value" => val}, socket) do
    socket = assign(socket, :filter_query, val || "") |> push_filtered_graph()
    {:noreply, socket}
  end

  def handle_event("toggle_show_anon", _params, socket) do
    new_val = !socket.assigns.show_anon
    socket = assign(socket, :show_anon, new_val) |> push_event("graph_toggle_anon", %{})
    {:noreply, socket}
  end

  def handle_event("clear_filters", _params, socket) do
    socket =
      socket
      |> assign(:filter_status, nil)
      |> assign(:filter_namespace, nil)
      |> assign(:filter_agent_type, nil)
      |> assign(:filter_query, "")
      |> push_filtered_graph()

    {:noreply, socket}
  end

  def handle_event("toggle_node", %{"node_id" => _node_id}, socket) do
    # Acknowledge toggle from JS (expand state is maintained client-side)
    {:noreply, socket}
  end

  def handle_event("graph_anon_toggled", %{"show" => show}, socket) do
    {:noreply, assign(socket, :show_anon, show)}
  end

  def handle_event("scan_ports", _params, socket) do
    safe_call(fn -> PortManager.scan_active_ports() end, :ok)
    project_configs = safe_call(fn -> PortManager.get_project_configs() end, %{})
    port_clashes = safe_call(fn -> PortManager.detect_clashes() end, [])
    {:noreply,
     socket
     |> assign(:project_configs, project_configs)
     |> assign(:port_clashes, port_clashes)}
  end

  def handle_event("get_remediation", %{"port" => port_str}, socket) do
    {port, _} = Integer.parse(port_str)
    remediation = safe_call(fn -> PortManager.suggest_remediation(port) end, "")
    {:noreply, assign(socket, :port_remediation, remediation)}
  end

  def handle_event("save_layout", %{"name" => name}, socket) do
    panels = []
    {:ok, _layout} = DashboardStore.save_layout(name, panels)
    {:noreply, assign(socket, :saved_layouts, DashboardStore.list_layouts())}
  end

  def handle_event("load_layout", %{"id" => id}, socket) do
    case DashboardStore.load_layout(id) do
      nil -> {:noreply, socket}
      _layout -> {:noreply, socket}
    end
  end

  def handle_event("save_filter_preset", %{"name" => name}, socket) do
    filters = %{
      "status" => socket.assigns.filter_status,
      "namespace" => socket.assigns.filter_namespace,
      "agent_type" => socket.assigns.filter_agent_type,
      "search" => socket.assigns.filter_query
    }

    {:ok, _preset} = DashboardStore.save_preset(name, filters)
    {:noreply, assign(socket, :saved_presets, DashboardStore.list_presets())}
  end

  def handle_event("load_filter_preset", %{"id" => id}, socket) do
    case DashboardStore.load_preset(id) do
      nil ->
        {:noreply, socket}

      preset ->
        filters = preset["filters"]

        socket =
          socket
          |> assign(:filter_status, filters["status"])
          |> assign(:filter_namespace, filters["namespace"])
          |> assign(:filter_agent_type, filters["agent_type"])
          |> assign(:filter_query, filters["search"] || "")
          |> push_filtered_graph()

        {:noreply, socket}
    end
  end

  # --- PubSub Handlers ---

  @impl true
  def handle_info({:agent_registered, _agent}, socket) do
    {:noreply, refresh_agents(socket)}
  end

  def handle_info({:agent_updated, _agent}, socket) do
    {:noreply, refresh_agents(socket)}
  end

  def handle_info({:agent_discovered, _agent_id, _project}, socket) do
    {:noreply, refresh_agents(socket)}
  end

  def handle_info({:notification_added, notif}, socket) do
    notifications = AgentRegistry.get_notifications()

    socket =
      socket
      |> assign(:notifications, notifications)
      |> maybe_push_toast(notif)

    {:noreply, socket}
  end

  def handle_info(:notifications_read, socket) do
    notifications = AgentRegistry.get_notifications()
    {:noreply, assign(socket, :notifications, notifications)}
  end

  def handle_info({:config_reloaded, config}, socket) do
    projects = Map.get(config, "projects", [])
    active = Map.get(config, "active_project")
    ralph_data = load_ralph_for_project(active, config)
    session_count = live_session_count(config)

    socket =
      socket
      |> assign(:projects, projects)
      |> assign(:active_project, active)
      |> assign(:project_cats, categorize_projects(projects, active))
      |> assign(:ralph_data, ralph_data)
      |> assign(:session_count, session_count)

    {:noreply, refresh_agents(socket)}
  end

  def handle_info({:tasks_synced, _project, _tasks}, socket) do
    project = socket.assigns.active_project || "_global"
    tasks = ProjectStore.get_tasks(project)
    {:noreply, assign(socket, :tasks, tasks)}
  end

  def handle_info({:commands_updated, _project}, socket) do
    project = socket.assigns.active_project || "_global"
    commands = ProjectStore.get_commands(project)
    {:noreply, assign(socket, :commands, commands)}
  end

  def handle_info({:upm_session_registered, _session}, socket) do
    {:noreply, assign(socket, :upm_status, UpmStore.get_status())}
  end

  def handle_info({:upm_agent_registered, _params}, socket) do
    {:noreply, assign(socket, :upm_status, UpmStore.get_status())}
  end

  def handle_info({:upm_event, _event}, socket) do
    {:noreply, assign(socket, :upm_status, UpmStore.get_status())}
  end

  def handle_info({:port_assigned, _, _}, socket) do
    project_configs = safe_call(fn -> PortManager.get_project_configs() end, %{})
    port_clashes = safe_call(fn -> PortManager.detect_clashes() end, [])
    {:noreply, socket |> assign(:project_configs, project_configs) |> assign(:port_clashes, port_clashes)}
  end

  # US-017: Handle AG-UI EventBus events
  def handle_info({:event_bus, "lifecycle:" <> _, %{type: type}}, socket)
      when type in ["RUN_STARTED", "RUN_FINISHED", "RUN_ERROR", "STEP_STARTED", "STEP_FINISHED"] do
    {:noreply, refresh_agents(socket)}
  end

  def handle_info({:event_bus, "state:" <> _, _event}, socket) do
    {:noreply, refresh_agents(socket)}
  end

  def handle_info({:event_bus, "activity:" <> _, _event}, socket) do
    {:noreply, refresh_agents(socket)}
  end

  def handle_info({:event_bus, "special:custom", %{data: %{name: "approval_requested"}}}, socket) do
    pending = Apm.AgUi.ApprovalGate.pending_count()
    {:noreply, assign(socket, :pending_approvals, pending)}
  end

  def handle_info({:event_bus, _, _}, socket), do: {:noreply, socket}

  # Chat PubSub — live message updates from ChatStore
  def handle_info({:chat_event, scope, {:new_message, _message}}, socket) do
    if scope == socket.assigns.chat_scope do
      messages = ChatStore.list_messages(scope, 50)
      {:noreply, assign(socket, :chat_messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:chat_event, _scope, :cleared}, socket) do
    {:noreply, assign(socket, :chat_messages, [])}
  end

  # US-003: AgentLock pending decision real-time updates (floating banner)
  def handle_info({:pending_decision_added, entry}, socket) do
    pending = [entry | socket.assigns.agentlock_pending]
    {:noreply,
     socket
     |> assign(:agentlock_pending, pending)
     |> assign(:auth_dismissed, false)
     |> push_event("show_toast", %{
       type: "warning",
       title: "AgentLock: Approval Required",
       message: "#{entry.tool_name} — #{entry.risk_level} risk",
       category: "agentlock"
     })}
  end

  def handle_info({:pending_decision_resolved, entry}, socket) do
    pending = Enum.reject(socket.assigns.agentlock_pending, &(&1.request_id == entry.request_id))
    {:noreply, assign(socket, :agentlock_pending, pending)}
  end

  # AgentLock authorization decision toasts
  def handle_info({:auth_denied, %{tool_name: tool, agent_id: _agent} = data}, socket) do
    risk = data |> Map.get(:risk_level, :unknown) |> to_string()
    {:noreply, push_event(socket, "show_toast", %{
      type: "error",
      title: "AgentLock: #{tool} DENIED",
      message: "risk: #{risk}",
      category: "agentlock"
    })}
  end

  def handle_info({:auth_granted, %{tool_name: tool} = data}, socket) do
    risk = data |> Map.get(:risk_level, :none) |> to_string()

    if risk in ["high", "critical"] do
      {:noreply, push_event(socket, "show_toast", %{
        type: "warning",
        title: "AgentLock: #{tool} authorized",
        message: "high risk operation permitted",
        category: "agentlock"
      })}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:auth_escalated, %{tool_name: tool}}, socket) do
    {:noreply, push_event(socket, "show_toast", %{
      type: "warning",
      title: "AgentLock: #{tool} escalated",
      message: "approval required",
      category: "agentlock"
    })}
  end

  def handle_info({:token_consumed, _}, socket), do: {:noreply, socket}

  # ── Widgetization Engine — Scope PubSub handlers (US-360) ────────────────────

  def handle_info({:scope_changed, scope_type, scope_value}, socket) do
    {:noreply,
     socket
     |> assign(:widget_scope_type, scope_type)
     |> assign(:widget_scope_value, scope_value)}
  end

  def handle_info({:pinned_widget_changed, widget_id}, socket) do
    {:noreply, assign(socket, :widget_pinned_id, widget_id)}
  end

  def handle_info({:widget_config_updated, _widget_id, _config}, socket) do
    # Config stored in WidgetConfigStore; re-render will pick it up via assigns
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp refresh_agents(socket) do
    project = socket.assigns.active_project
    agents = AgentRegistry.list_agents(project)

    socket
    |> assign(:agents, agents)
    |> update_agent_counts(agents)
    |> push_graph_data(agents)
  end

  defp update_agent_counts(socket, agents) do
    socket
    |> assign(:agent_count, length(agents))
    |> assign(:active_count, Enum.count(agents, &(&1.status == "active")))
    |> assign(:idle_count, Enum.count(agents, &(&1.status == "idle")))
    |> assign(:error_count, Enum.count(agents, &(&1.status == "error")))
  end

  # --- Helper Components ---

  # stat_card removed — replaced by design_system stat_tile (Wave 5)

  # --- Private Helpers ---

  defp filtered_agents(assigns) do
    assigns.agents
    |> filter_by_status(assigns[:filter_status])
    |> filter_by_namespace(assigns[:filter_namespace])
    |> filter_by_agent_type(assigns[:filter_agent_type])
    |> filter_by_query(assigns[:filter_query])
  end

  defp maybe_push_toast(socket, notif) do
    category = Map.get(notif, :category) || Map.get(notif, "category")

    if category in ["agent", "formation", :agent, :formation] do
      push_event(socket, "show_toast", %{
        type: to_string(Map.get(notif, :type, Map.get(notif, :level, "info"))),
        title: Map.get(notif, :title, ""),
        message: Map.get(notif, :message, ""),
        category: to_string(category),
        agent_id: Map.get(notif, :agent_id)
      })
    else
      socket
    end
  end

  defp push_filtered_graph(socket) do
    filtered = filtered_agents(socket.assigns)
    push_graph_data(socket, filtered)
  end

  defp push_graph_data(socket, agents) do
    graph_agents =
      Enum.map(agents, fn agent ->
        %{
          id: agent.id,
          name: agent.name,
          tier: agent.tier,
          status: agent.status,
          deps: agent.deps || [],
          metadata: agent.metadata || %{},
          namespace: agent[:namespace],
          agent_type: agent[:agent_type] || "individual",
          member_count: agent[:member_count],
          path: agent[:path],
          project_name: agent[:project_name]
        }
      end)

    agent_ids = MapSet.new(Enum.map(agents, & &1.id))

    edges =
      agents
      |> Enum.flat_map(fn agent ->
        (agent.deps || [])
        |> Enum.filter(&MapSet.member?(agent_ids, &1))
        |> Enum.map(fn dep_id -> %{source: dep_id, target: agent.id} end)
      end)

    # Push flat agents_updated (backward compat for legacy graph)
    socket = push_event(socket, "agents_updated", %{agents: graph_agents, edges: edges})

    # Push hierarchy_data via GraphBuilder for collapsible tree
    hierarchy = GraphBuilder.build_hierarchy(graph_agents, scope: :single_project)
    socket = assign(socket, :hierarchy, hierarchy)
    push_event(socket, "hierarchy_data", %{tree: hierarchy})
  end

  defp calculate_uptime, do: Apm.Uptime.formatted()

  defp format_last_seen(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)

        cond do
          diff < 60 -> "#{diff}s ago"
          diff < 3600 -> "#{div(diff, 60)}m ago"
          true -> "#{div(diff, 3600)}h ago"
        end

      _ ->
        "unknown"
    end
  end

  defp format_last_seen(_), do: "unknown"

  defp skill_count do
    try do
      map_size(Apm.SkillTracker.get_skill_catalog())
    catch
      :exit, _ -> 0
    end
  end

  defp load_ralph_for_project(project_name, config) do
    project_config =
      if project_name do
        config
        |> Map.get("projects", [])
        |> Enum.find(fn p -> p["name"] == project_name end)
      end

    prd_path = if project_config, do: project_config["prd_json"]

    # Multi-signal Ralph detection:
    # 1. prd_json path in config (existing)
    # 2. SkillTracker methodology detection
    # 3. .claude/ralph/ directory presence
    ralph_detected =
      prd_path != nil or
      ralph_detected_via_skills?() or
      ralph_dir_present?(project_config)

    case Ralph.load(prd_path) do
      {:ok, data} ->
        data

      _ when ralph_detected ->
        %{project: project_name || "", branch: "", description: "Ralph detected via skills/directory",
          stories: [], total: 0, passed: 0}

      _ ->
        %{project: "", branch: "", description: "", stories: [], total: 0, passed: 0}
    end
  end

  defp ralph_detected_via_skills? do
    try do
      catalog = Apm.SkillTracker.get_skill_catalog()
      Map.has_key?(catalog, "ralph")
    catch
      :exit, _ -> false
    end
  end

  defp ralph_dir_present?(nil), do: false
  defp ralph_dir_present?(project_config) do
    root = project_config["root"]
    root != nil and File.dir?(Path.join(root, ".claude/ralph"))
  end

  defp count_config_sessions(config) do
    config
    |> Map.get("projects", [])
    |> Enum.flat_map(fn p -> Map.get(p, "sessions", []) end)
    |> length()
  end

  # CP-333 (US-513): SESSIONS stat tile prefers SessionManager (disk-backed, real-time)
  # over count_config_sessions (apm_config.json projects[].sessions which is never hydrated).
  # Falls back to the config-based count if SessionManager isn't running.
  defp live_session_count(config) do
    try do
      Apm.SessionManager.list_sessions() |> length()
    rescue
      _ -> count_config_sessions(config)
    catch
      :exit, _ -> count_config_sessions(config)
    end
  end

  defp categorize_projects(projects, active_project) do
    now = DateTime.utc_now()
    thirty_days_ago = DateTime.add(now, -30 * 24 * 3600, :second)

    Enum.reduce(projects, %{active: [], recent: [], other: []}, fn project, acc ->
      name = project["name"]
      sessions = project["sessions"] || []

      last_active =
        sessions
        |> Enum.map(fn s -> s["start_time"] end)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(fn ts ->
          case DateTime.from_iso8601(ts) do
            {:ok, dt, _} -> dt
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort({:desc, DateTime})
        |> List.first()

      cond do
        name == active_project ->
          %{acc | active: [project | acc.active]}

        last_active != nil and DateTime.compare(last_active, thirty_days_ago) == :gt ->
          %{acc | recent: [project | acc.recent]}

        true ->
          %{acc | other: [project | acc.other]}
      end
    end)
    |> then(fn cats ->
      %{
        active: Enum.reverse(cats.active),
        recent: cats.recent |> Enum.reverse() |> Enum.take(8),
        other: Enum.reverse(cats.other)
      }
    end)
  end

  # --- UPM Helpers ---

  defp upm_story_summary(stories) when is_list(stories) do
    passed = Enum.count(stories, &(&1.status == "passed"))
    total = length(stories)
    "#{passed}/#{total} passed"
  end
  defp upm_story_summary(_), do: ""

  defp safe_get_config do
    try do
      ConfigLoader.get_config()
    catch
      :exit, _ -> %{"projects" => [], "active_project" => nil}
    end
  end

  # --- Hierarchy List Helpers ---

  # Walk a hierarchy tree and return the list of ancestor node IDs (incl. target) if found.
  defp find_ancestor_path(nil, _target_id), do: nil

  defp find_ancestor_path(node, target_id) do
    node_id = node["id"] || node[:id]

    if node_id == target_id do
      [node_id]
    else
      children =
        (node["children"] || node[:children] || []) ++
          (node["_children"] || node[:_children] || [])

      Enum.find_value(children, fn child ->
        case find_ancestor_path(child, target_id) do
          nil -> nil
          path -> [node_id | path]
        end
      end)
    end
  end

  # Recursive tree node component for the list view
  attr :node, :map, required: true
  attr :depth, :integer, default: 0
  attr :expanded, :any, required: true
  attr :selected_id, :string, default: nil

  defp tree_node(assigns) do
    node = assigns.node
    node_id = node["id"] || node[:id] || ""
    node_name = node["name"] || node[:name] || node_id
    node_type = node["type"] || node[:type] || "unknown"
    node_status = node["status"] || node[:status] || "idle"
    agent_count = node["agent_count"] || node[:agent_count] || 0
    children = node["children"] || node[:children] || []
    has_children = children != []
    is_expanded = MapSet.member?(assigns.expanded, node_id)
    is_selected = assigns.selected_id == node_id && node_type == "agent"
    indent = assigns.depth * 16

    assigns =
      assigns
      |> assign(:node_id, node_id)
      |> assign(:node_name, node_name)
      |> assign(:node_type, node_type)
      |> assign(:node_status, node_status)
      |> assign(:agent_count, agent_count)
      |> assign(:children, children)
      |> assign(:has_children, has_children)
      |> assign(:is_expanded, is_expanded)
      |> assign(:is_selected, is_selected)
      |> assign(:indent, indent)

    ~H"""
    <div>
      <div
        class={[
          "flex items-center gap-1.5 py-1 px-2 rounded-lg transition-colors",
          "hover:bg-base-200 cursor-pointer group",
          @is_selected && "bg-primary/10 ring-1 ring-primary/30"
        ]}
        style={"padding-left: #{@indent + 8}px"}
        phx-click={if @has_children, do: "toggle_list_node", else: "select_agent"}
        phx-value-node_id={if @has_children, do: @node_id}
        phx-value-agent_id={unless @has_children, do: @node_id}
      >
        <%!-- Expand/collapse chevron --%>
        <span class="w-3 flex-shrink-0 text-[10px] text-base-content/40">
          <%= cond do %>
            <% @has_children && @is_expanded -> %>&#x25BE;
            <% @has_children -> %>&#x25B8;
            <% true -> %>&nbsp;
          <% end %>
        </span>

        <%!-- Type icon --%>
        <span class={["text-[11px] flex-shrink-0", status_text_class(@node_status)]}>
          <%= node_type_icon(@node_type) %>
        </span>

        <%!-- Name --%>
        <span class={[
          "text-xs flex-1 truncate",
          @node_type == "agent" && "font-mono",
          @is_selected && "text-primary font-medium"
        ]}>
          {@node_name}
        </span>

        <%!-- Agent count badge for non-leaf nodes --%>
        <%= if @has_children && @agent_count > 0 do %>
          <span class="text-[9px] text-base-content/30 flex-shrink-0">{@agent_count}</span>
        <% end %>

        <%!-- Status dot for agents --%>
        <%= if @node_type == "agent" do %>
          <span class={["w-1.5 h-1.5 rounded-full flex-shrink-0", status_dot_class(@node_status)]}></span>
        <% end %>
      </div>

      <%!-- Children --%>
      <div :if={@has_children && @is_expanded}>
        <.tree_node
          :for={child <- @children}
          node={child}
          depth={@depth + 1}
          expanded={@expanded}
          selected_id={@selected_id}
        />
      </div>
    </div>
    """
  end

  defp node_type_icon("root"), do: "\u25A1"
  defp node_type_icon("project"), do: "\u25A3"
  defp node_type_icon("formation"), do: "\u25C9"
  defp node_type_icon("squadron"), do: "\u25A0"
  defp node_type_icon("agent"), do: "\u25CB"
  defp node_type_icon(_), do: "\u25A1"

  defp status_text_class("active"), do: "text-success"
  defp status_text_class("running"), do: "text-success"
  defp status_text_class("error"), do: "text-error"
  defp status_text_class("warning"), do: "text-warning"
  defp status_text_class("completed"), do: "text-purple-400"
  defp status_text_class(_), do: "text-base-content/40"

  defp safe_call(fun, default) do
    try do
      fun.()
    catch
      :exit, _ -> default
      _, _ -> default
    end
  end

  defp safe_list_pending do
    try do
      Apm.Auth.PendingDecisions.list_pending()
    rescue
      _ -> []
    end
  end

  defp status_dot_class("active"), do: "bg-success"
  defp status_dot_class("running"), do: "bg-success"
  defp status_dot_class("error"), do: "bg-error"
  defp status_dot_class("warning"), do: "bg-warning"
  defp status_dot_class("completed"), do: "bg-purple-400"
  defp status_dot_class(_), do: "bg-base-content/30"

  defp upm_tone("registered"), do: "neutral"
  defp upm_tone("running"), do: "info"
  defp upm_tone("verifying"), do: "warning"
  defp upm_tone("verified"), do: "success"
  defp upm_tone("shipped"), do: "accent"
  defp upm_tone(_), do: "neutral"

  defp agent_status_tone("active"), do: "success"
  defp agent_status_tone("idle"), do: "neutral"
  defp agent_status_tone("error"), do: "error"
  defp agent_status_tone("discovered"), do: "info"
  defp agent_status_tone("completed"), do: "accent"
  defp agent_status_tone(_), do: "neutral"
end
