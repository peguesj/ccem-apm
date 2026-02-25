defmodule ApmV4Web.AllProjectsLive do
  @moduledoc """
  All-projects widget dashboard for CCEM APM v4.

  Industry-standard widget dashboard with:
    - KPI summary cards at the top
    - Resizable, collapsible, lockable widgets
    - Drill-down: click a project or agent to filter
    - Real-time updates via PubSub
    - Responsive 12-column CSS grid
  """

  use ApmV4Web, :live_view

  alias ApmV4.AgentRegistry
  alias ApmV4.ConfigLoader
  alias ApmV4.GraphBuilder
  alias ApmV4.Ralph

  # Widget definitions: id, title, default grid span, default height (px)
  @default_widgets [
    %{id: "kpi",           title: "KPI Overview",        cols: 12, height: nil,  locked: false, collapsed: false},
    %{id: "projects",      title: "Projects",             cols: 6,  height: 260,  locked: false, collapsed: false},
    %{id: "dep-graph",     title: "Dependency Graph",     cols: 6,  height: 260,  locked: false, collapsed: false},
    %{id: "agent-fleet",   title: "Agent Fleet",          cols: 8,  height: 320,  locked: false, collapsed: false},
    %{id: "notifications", title: "Notifications",        cols: 4,  height: 320,  locked: false, collapsed: false},
    %{id: "ralph-status",  title: "Ralph / PRD Status",   cols: 6,  height: 300,  locked: false, collapsed: false},
    %{id: "activity",      title: "Session Activity",     cols: 6,  height: 300,  locked: false, collapsed: false}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:agents")
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:notifications")
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:config")
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:tasks")
    end

    config = safe_config()
    projects = Map.get(config, "projects", [])
    agents = AgentRegistry.list_agents()
    notifications = AgentRegistry.get_notifications()
    session_count = count_sessions(config)

    widgets = @default_widgets |> Enum.into(%{}, fn w -> {w.id, w} end)

    socket =
      socket
      |> assign(:page_title, "APM — All Projects")
      |> assign(:active_nav, :all)
      |> assign(:config, config)
      |> assign(:projects, projects)
      |> assign(:agents, agents)
      |> assign(:active_count, Enum.count(agents, &(&1.status == "active")))
      |> assign(:notifications, notifications)
      |> assign(:session_count, session_count)
      |> assign(:widgets, widgets)
      |> assign(:drill_project, nil)
      |> assign(:uptime, uptime())
      |> push_graph_data(agents)
      |> assign(:ralph_data, %{})
      |> assign(:upm_status, %{})
      |> assign(:inspector_tab, :ralph)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <%!-- Sidebar --%>
      <aside class="w-14 bg-base-200 border-r border-base-300 flex flex-col flex-shrink-0 items-center py-3 gap-2">
        <%!-- Brand / counts --%>
        <div class="tooltip tooltip-right mb-1" data-tip={"#{length(@projects)} projects · #{@active_count} active"}>
          <span class="inline-block w-2 h-2 rounded-full bg-success animate-pulse"></span>
        </div>
        <a href="/" class="tooltip tooltip-right" data-tip="Dashboard">
          <button class="btn btn-ghost btn-sm btn-square">
            <.icon name="hero-squares-2x2" class="size-4" />
          </button>
        </a>
        <a href="/apm-all" class="tooltip tooltip-right" data-tip="All Projects">
          <button class="btn btn-primary btn-sm btn-square">
            <.icon name="hero-globe-alt" class="size-4" />
          </button>
        </a>
        <a href="/skills" class="tooltip tooltip-right" data-tip="Skills">
          <button class="btn btn-ghost btn-sm btn-square">
            <.icon name="hero-sparkles" class="size-4" />
          </button>
        </a>
        <a href="/ralph" class="tooltip tooltip-right" data-tip="Ralph">
          <button class="btn btn-ghost btn-sm btn-square">
            <.icon name="hero-arrow-path" class="size-4" />
          </button>
        </a>
        <a href="/timeline" class="tooltip tooltip-right" data-tip="Timeline">
          <button class="btn btn-ghost btn-sm btn-square">
            <.icon name="hero-clock" class="size-4" />
          </button>
        </a>
        <a href="/formation" class="tooltip tooltip-right" data-tip="Formations">
          <button class="btn btn-ghost btn-sm btn-square">
            <.icon name="hero-rectangle-group" class="size-4" />
          </button>
        </a>
        <a href="/docs" class="tooltip tooltip-right" data-tip="Docs">
          <button class="btn btn-ghost btn-sm btn-square">
            <.icon name="hero-book-open" class="size-4" />
          </button>
        </a>
        <div class="flex-1" />
        <div class="text-[9px] text-base-content/30 text-center rotate-180" style="writing-mode:vertical-lr">
          {@uptime}
        </div>
      </aside>

      <%!-- Main --%>
      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Top bar --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold">All Projects</h2>
            <div :if={@drill_project} class="flex items-center gap-1">
              <span class="text-base-content/40 text-xs">›</span>
              <span class="badge badge-sm badge-primary">{@drill_project}</span>
              <button class="btn btn-ghost btn-xs" phx-click="clear_drill">
                <.icon name="hero-x-mark" class="size-3" />
              </button>
            </div>
          </div>
          <div class="flex items-center gap-3">
            <span class="text-xs text-base-content/40" id="clock-all" phx-hook="Clock">--:--</span>
            <div class="badge badge-sm badge-success gap-1">
              <span class="inline-block w-1.5 h-1.5 rounded-full bg-success animate-pulse"></span>
              LIVE
            </div>
            <%!-- Notifications bell --%>
            <div class="dropdown dropdown-end">
              <div tabindex="0" role="button" class="btn btn-ghost btn-sm btn-circle indicator">
                <.icon name="hero-bell" class="size-4" />
                <span :if={length(@notifications) > 0} class="indicator-item badge badge-xs badge-error">
                  {length(@notifications)}
                </span>
              </div>
              <div tabindex="0" class="dropdown-content z-50 w-80 mt-2">
                <div class="card bg-base-200 border border-base-300 shadow-xl">
                  <div class="card-body p-3">
                    <h3 class="text-xs font-semibold uppercase tracking-wider mb-2">Notifications</h3>
                    <div class="space-y-1 max-h-48 overflow-y-auto">
                      <div :for={n <- Enum.take(@notifications, 8)} class="p-2 rounded bg-base-300 text-xs">
                        <div class="flex gap-2 items-center">
                          <span class={["badge badge-xs", notif_class(n.level)]}>{n.level}</span>
                          <span class="font-medium truncate">{n.title}</span>
                        </div>
                        <p class="text-base-content/50 truncate mt-0.5">{n.message}</p>
                      </div>
                      <p :if={@notifications == []} class="text-center text-base-content/40 py-3 text-xs">
                        No notifications
                      </p>
                    </div>
                  </div>
                </div>
              </div>
            </div>
            <Layouts.theme_toggle />
          </div>
        </header>

        <%!-- Widget Grid --%>
        <div class="flex-1 overflow-y-auto p-4">
          <div class="grid grid-cols-12 gap-4 auto-rows-min">

            <%!-- KPI Widget (always full width) --%>
            <.widget
              id="kpi"
              widget={@widgets["kpi"]}
              extra_class="col-span-12"
            >
              <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3">
                <.kpi label="Projects" value={length(@projects)} color="text-primary" icon="hero-folder" />
                <.kpi label="Agents" value={length(@agents)} color="text-info" icon="hero-cpu-chip" />
                <.kpi label="Active" value={Enum.count(@agents, &(&1.status == "active"))} color="text-success" icon="hero-play" />
                <.kpi label="Sessions" value={@session_count} color="text-secondary" icon="hero-clock" />
                <.kpi label="Errors" value={Enum.count(@agents, &(&1.status == "error"))} color="text-error" icon="hero-exclamation-triangle" />
                <.kpi label="Notifications" value={length(@notifications)} color="text-warning" icon="hero-bell" />
              </div>
            </.widget>

            <%!-- Projects Widget --%>
            <.widget
              id="projects"
              widget={@widgets["projects"]}
              extra_class="col-span-12 md:col-span-6"
            >
              <div class="space-y-2 overflow-y-auto" style={widget_height(@widgets["projects"])}>
                <div
                  :for={project <- @projects}
                  class={[
                    "rounded-lg border p-3 cursor-pointer transition-all hover:border-primary/50",
                    @drill_project == project["name"] && "border-primary bg-primary/5" || "border-base-300 bg-base-300"
                  ]}
                  phx-click="drill_project"
                  phx-value-name={project["name"]}
                >
                  <div class="flex items-center justify-between">
                    <span class="font-medium text-sm truncate">{project["name"]}</span>
                    <div class="flex items-center gap-2 flex-shrink-0">
                      <span class="badge badge-xs badge-success">active</span>
                    </div>
                  </div>
                  <div class="flex gap-3 mt-1.5 text-xs text-base-content/50">
                    <span>
                      <span class="text-primary font-medium">
                        {length(AgentRegistry.list_agents(project["name"]))}
                      </span> agents
                    </span>
                    <span>
                      <span class="font-medium">
                        {length(Map.get(project, "sessions", []))}
                      </span> sessions
                    </span>
                    <span :if={project["prd_json"] != ""} class="text-success">PRD ✓</span>
                  </div>
                  <div class="text-[10px] text-base-content/30 mt-1 truncate">{project["root"]}</div>
                </div>
                <div :if={@projects == []} class="text-center text-base-content/30 py-8 text-sm">
                  No projects registered
                </div>
              </div>
            </.widget>

            <%!-- Dependency Graph Widget --%>
            <.widget
              id="dep-graph"
              widget={@widgets["dep-graph"]}
              extra_class="col-span-12 md:col-span-6"
            >
              <div
                id="dep-graph-all"
                class="w-full rounded-xl relative overflow-hidden"
                style={"background: #151b28; #{widget_height(@widgets["dep-graph"])}"}
                phx-hook="DependencyGraph"
                phx-update="ignore"
              >
              </div>
            </.widget>

            <%!-- Agent Fleet Widget --%>
            <.widget
              id="agent-fleet"
              widget={@widgets["agent-fleet"]}
              extra_class="col-span-12 lg:col-span-8"
            >
              <div class="overflow-auto" style={widget_height(@widgets["agent-fleet"])}>
                <table class="table table-xs w-full">
                  <thead class="sticky top-0 bg-base-200">
                    <tr class="text-[10px] uppercase tracking-wider text-base-content/40">
                      <th class="w-8">T</th>
                      <th>Agent</th>
                      <th>Project</th>
                      <th>Status</th>
                      <th class="text-right">Seen</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={agent <- visible_agents(@agents, @drill_project)}
                      class="hover cursor-pointer"
                      phx-click="inspect_agent"
                      phx-value-id={agent.id}
                    >
                      <td>
                        <span class={["badge badge-xs", tier_class(agent.tier)]}>
                          {agent.tier}
                        </span>
                      </td>
                      <td>
                        <div class="font-medium truncate max-w-[180px]">{agent.name}</div>
                        <div class="text-[10px] text-base-content/30 font-mono">{String.slice(agent.id, 0, 8)}</div>
                      </td>
                      <td class="text-base-content/50 text-xs">
                        {get_in(agent, [:project_name]) || get_in(agent, [:metadata, "project"]) || "—"}
                      </td>
                      <td>
                        <span class={["badge badge-sm", status_class(agent.status)]}>
                          {agent.status}
                        </span>
                      </td>
                      <td class="text-right text-xs text-base-content/40">
                        {format_seen(agent.last_seen)}
                      </td>
                    </tr>
                    <tr :if={@agents == []}>
                      <td colspan="5" class="text-center text-base-content/30 py-6">No agents</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </.widget>

            <%!-- Notifications Widget --%>
            <.widget
              id="notifications"
              widget={@widgets["notifications"]}
              extra_class="col-span-12 lg:col-span-4"
            >
              <div class="space-y-1.5 overflow-y-auto" style={widget_height(@widgets["notifications"])}>
                <div
                  :for={n <- Enum.take(@notifications, 50)}
                  class="p-2 rounded bg-base-300 text-xs group hover:bg-base-100 transition-colors"
                >
                  <div class="flex items-center gap-2">
                    <span class={["badge badge-xs flex-shrink-0", notif_class(n.level)]}>{n.level}</span>
                    <span class="font-medium truncate flex-1">{n.title}</span>
                    <span class="text-base-content/30 text-[10px] flex-shrink-0">{format_notif_time(n)}</span>
                  </div>
                  <p class="text-base-content/50 mt-0.5 truncate">{n.message}</p>
                </div>
                <div :if={@notifications == []} class="text-center text-base-content/30 py-8 text-xs">
                  No notifications
                </div>
              </div>
            </.widget>

            <%!-- Ralph Status Widget --%>
            <.widget
              id="ralph-status"
              widget={@widgets["ralph-status"]}
              extra_class="col-span-12 md:col-span-6"
            >
              <div class="space-y-3 overflow-y-auto" style={widget_height(@widgets["ralph-status"])}>
                <div :for={project <- @projects} class={[
                  "rounded border p-3",
                  project["prd_json"] != "" && "border-base-300" || "border-base-300/40 opacity-50"
                ]}>
                  <div class="flex items-center justify-between mb-1.5">
                    <span class="text-xs font-medium">{project["name"]}</span>
                    <span :if={project["prd_json"] != ""} class="text-[10px] text-base-content/40">
                      {ralph_summary(project["prd_json"])}
                    </span>
                    <span :if={project["prd_json"] == ""} class="text-[10px] text-base-content/30">
                      no PRD
                    </span>
                  </div>
                  <div :if={project["prd_json"] != ""} class="w-full bg-base-300 rounded-full h-1">
                    <div
                      class="bg-success h-1 rounded-full"
                      style={"width: #{ralph_progress(project["prd_json"])}%"}
                    ></div>
                  </div>
                </div>
                <div :if={@projects == []} class="text-center text-base-content/30 py-8 text-xs">
                  No projects
                </div>
              </div>
            </.widget>

            <%!-- Session Activity Widget --%>
            <.widget
              id="activity"
              widget={@widgets["activity"]}
              extra_class="col-span-12 md:col-span-6"
            >
              <div class="space-y-1.5 overflow-y-auto" style={widget_height(@widgets["activity"])}>
                <div :for={session <- recent_sessions(@config)} class="flex items-start gap-3 p-2 rounded bg-base-300 text-xs hover:bg-base-100 transition-colors">
                  <div class="w-2 h-2 rounded-full bg-success mt-1 flex-shrink-0 animate-pulse"></div>
                  <div class="flex-1 min-w-0">
                    <div class="font-medium">{session.project}</div>
                    <div class="text-base-content/40 font-mono text-[10px]">
                      {String.slice(session.id, 0, 12)}
                    </div>
                  </div>
                  <div class="text-base-content/30 text-[10px] flex-shrink-0">{session.time}</div>
                </div>
                <div :if={recent_sessions(@config) == []} class="text-center text-base-content/30 py-8 text-xs">
                  No recent sessions
                </div>
              </div>
            </.widget>

            <%!-- Inspector Panel Widget --%>
            <.widget
              id="inspector"
              widget={@widgets["inspector"] || %{id: "inspector", title: "Inspector", locked: false, collapsed: false, height: 280}}
              extra_class="col-span-12"
            >
              <%!-- Tab bar --%>
              <div class="flex gap-0.5 mb-3 border-b border-base-300 pb-2">
                <%= for {label, tab} <- [{"Ralph", :ralph}, {"UPM", :upm}, {"Ports", :ports}, {"Commands", :commands}, {"TODOs", :todos}] do %>
                  <button
                    class={[
                      "px-3 py-1 text-xs font-medium rounded-t transition-colors",
                      @inspector_tab == tab && "bg-primary/10 text-primary border-b-2 border-primary",
                      @inspector_tab != tab && "text-base-content/50 hover:text-base-content hover:bg-base-300"
                    ]}
                    phx-click="switch_inspector_tab"
                    phx-value-tab={tab}
                  >
                    <%= label %>
                  </button>
                <% end %>
              </div>

              <%!-- Tab content --%>
              <div class="overflow-y-auto" style="max-height: 220px;">
                <%= if @inspector_tab == :ralph do %>
                  <%= if map_size(@ralph_data) > 0 do %>
                    <div class="space-y-2">
                      <div class="flex items-center justify-between text-xs">
                        <span class="text-base-content/50">Branch</span>
                        <span class="font-mono text-primary truncate max-w-[200px]">
                          {get_in(@ralph_data, ["branchName"]) || "—"}
                        </span>
                      </div>
                      <div class="flex items-center justify-between text-xs">
                        <span class="text-base-content/50">Stories</span>
                        <span class="font-mono">
                          {length(get_in(@ralph_data, ["userStories"]) || [])} total
                        </span>
                      </div>
                      <div class="flex items-center justify-between text-xs">
                        <span class="text-base-content/50">Passing</span>
                        <span class="font-mono text-success">
                          {Enum.count(get_in(@ralph_data, ["userStories"]) || [], &(&1["passes"] == true))} passed
                        </span>
                      </div>
                    </div>
                  <% else %>
                    <div class="flex flex-col items-center justify-center py-8 gap-2 text-base-content/30">
                      <.icon name="hero-arrow-path" class="size-6" />
                      <p class="text-xs">No prd.json for this project</p>
                    </div>
                  <% end %>
                <% end %>

                <%= if @inspector_tab == :upm do %>
                  <%= if map_size(@upm_status) > 0 do %>
                    <div class="space-y-2">
                      <div class="flex items-center justify-between text-xs">
                        <span class="text-base-content/50">Session</span>
                        <span class="font-mono truncate max-w-[200px] text-primary">
                          {get_in(@upm_status, ["upm_session_id"]) || "—"}
                        </span>
                      </div>
                      <div class="flex items-center justify-between text-xs">
                        <span class="text-base-content/50">Wave</span>
                        <span class="font-mono">{get_in(@upm_status, ["wave"]) || "—"}</span>
                      </div>
                      <div class="flex items-center justify-between text-xs">
                        <span class="text-base-content/50">Status</span>
                        <span class={[
                          "badge badge-xs",
                          case get_in(@upm_status, ["status"]) do
                            "running" -> "badge-success"
                            "failed"  -> "badge-error"
                            _         -> "badge-ghost"
                          end
                        ]}>
                          {get_in(@upm_status, ["status"]) || "idle"}
                        </span>
                      </div>
                    </div>
                  <% else %>
                    <div class="flex flex-col items-center justify-center py-8 gap-2 text-base-content/30">
                      <.icon name="hero-play-circle" class="size-6" />
                      <p class="text-xs">No active UPM session. Start with /upm build.</p>
                    </div>
                  <% end %>
                <% end %>

                <%= if @inspector_tab == :ports do %>
                  <div class="flex flex-col items-center justify-center py-8 gap-2 text-base-content/30">
                    <.icon name="hero-signal" class="size-6" />
                    <p class="text-xs">View port details on the Dashboard.</p>
                    <.link navigate={~p"/"} class="btn btn-xs btn-ghost text-primary mt-1">Go to Dashboard</.link>
                  </div>
                <% end %>

                <%= if @inspector_tab == :commands do %>
                  <div class="flex flex-col items-center justify-center py-8 gap-2 text-base-content/30">
                    <.icon name="hero-command-line" class="size-6" />
                    <p class="text-xs">No commands registered. POST to /api/commands to add.</p>
                  </div>
                <% end %>

                <%= if @inspector_tab == :todos do %>
                  <div class="flex flex-col items-center justify-center py-8 gap-2 text-base-content/30">
                    <.icon name="hero-check-circle" class="size-6" />
                    <p class="text-xs">No tasks synced. POST to /api/tasks/sync to add.</p>
                  </div>
                <% end %>
              </div>
            </.widget>

          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Widget Component ---

  attr :id, :string, required: true
  attr :widget, :map, required: true
  attr :extra_class, :string, default: ""
  slot :inner_block, required: true

  defp widget(assigns) do
    ~H"""
    <div class={["bg-base-200 border border-base-300 rounded-xl overflow-hidden", @extra_class]}>
      <div class="flex items-center justify-between px-3 py-2 border-b border-base-300 bg-base-200 select-none">
        <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
          {@widget.title}
        </h3>
        <div class="flex items-center gap-1">
          <button
            class={["btn btn-ghost btn-xs btn-square", @widget.locked && "text-warning" || "text-base-content/30"]}
            phx-click="toggle_lock"
            phx-value-id={@id}
            title={if @widget.locked, do: "Unlock (data frozen)", else: "Lock data"}
          >
            <.icon name={if @widget.locked, do: "hero-lock-closed", else: "hero-lock-open"} class="size-3" />
          </button>
          <button
            class="btn btn-ghost btn-xs btn-square text-base-content/30"
            phx-click="toggle_collapse"
            phx-value-id={@id}
            title={if @widget.collapsed, do: "Expand", else: "Collapse"}
          >
            <.icon name={if @widget.collapsed, do: "hero-chevron-down", else: "hero-chevron-up"} class="size-3" />
          </button>
        </div>
      </div>
      <div :if={!@widget.collapsed} class="p-3">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # --- KPI Component ---

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :color, :string, default: "text-primary"
  attr :icon, :string, required: true

  defp kpi(assigns) do
    ~H"""
    <div class="bg-base-300 rounded-lg p-3 flex items-center gap-3 hover:bg-base-100 transition-colors cursor-default">
      <div class={["p-2 rounded-lg bg-base-200", @color]}>
        <.icon name={@icon} class="size-4" />
      </div>
      <div>
        <div class={["text-2xl font-bold tabular-nums leading-none", @color]}>{@value}</div>
        <div class="text-[10px] uppercase tracking-wider text-base-content/40 mt-0.5">{@label}</div>
      </div>
    </div>
    """
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("drill_project", %{"name" => name}, socket) do
    # Toggle drill if same project clicked again
    new_drill = if socket.assigns.drill_project == name, do: nil, else: name
    {:noreply, assign(socket, :drill_project, new_drill)}
  end

  def handle_event("clear_drill", _params, socket) do
    {:noreply, assign(socket, :drill_project, nil)}
  end

  def handle_event("toggle_lock", %{"id" => widget_id}, socket) do
    widgets = update_widget(socket.assigns.widgets, widget_id, fn w ->
      %{w | locked: !w.locked}
    end)
    {:noreply, assign(socket, :widgets, widgets)}
  end

  def handle_event("toggle_collapse", %{"id" => widget_id}, socket) do
    widgets = update_widget(socket.assigns.widgets, widget_id, fn w ->
      %{w | collapsed: !w.collapsed}
    end)
    {:noreply, assign(socket, :widgets, widgets)}
  end

  def handle_event("widget_resize", %{"id" => widget_id, "height" => height}, socket) do
    h = max(120, min(800, round(height)))
    widgets = update_widget(socket.assigns.widgets, widget_id, fn w ->
      %{w | height: h}
    end)
    {:noreply, assign(socket, :widgets, widgets)}
  end

  def handle_event("inspect_agent", _params, socket) do
    # Navigate to main dashboard with agent selected — just redirect
    {:noreply, redirect(socket, to: "/")}
  end

  def handle_event("switch_inspector_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :inspector_tab, String.to_existing_atom(tab))}
  end

  # --- PubSub Handlers ---

  @impl true
  def handle_info({:agent_registered, _}, socket), do: refresh(socket)
  def handle_info({:agent_updated, _},    socket), do: refresh(socket)
  def handle_info({:agent_discovered, _, _}, socket), do: refresh(socket)

  def handle_info({:notification_added, notif}, socket) do
    socket =
      if socket.assigns.widgets["notifications"].locked do
        socket
      else
        assign(socket, :notifications, AgentRegistry.get_notifications())
      end

    # Push toast for agent/formation lifecycle events
    socket = maybe_push_toast(socket, notif)
    {:noreply, socket}
  end

  def handle_info({:config_reloaded, config}, socket) do
    projects = Map.get(config, "projects", [])
    session_count = count_sessions(config)

    {:noreply,
     socket
     |> assign(:config, config)
     |> assign(:projects, projects)
     |> assign(:session_count, session_count)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private ---

  defp refresh(socket) do
    if socket.assigns.widgets["agent-fleet"].locked do
      {:noreply, socket}
    else
      agents = AgentRegistry.list_agents()

      {:noreply,
       socket
       |> assign(:agents, agents)
       |> assign(:active_count, Enum.count(agents, &(&1.status == "active")))
       |> push_graph_data(agents)}
    end
  end

  defp push_graph_data(socket, agents) do
    graph_agents =
      Enum.map(agents, fn a ->
        %{
          id: a.id, name: a.name, tier: a.tier,
          status: a.status, deps: a.deps || [],
          metadata: a.metadata || %{}
        }
      end)

    agent_ids = MapSet.new(Enum.map(agents, & &1.id))
    edges =
      agents
      |> Enum.flat_map(fn a ->
        (a.deps || [])
        |> Enum.filter(&MapSet.member?(agent_ids, &1))
        |> Enum.map(fn dep -> %{source: dep, target: a.id} end)
      end)

    socket = push_event(socket, "agents_updated", %{agents: graph_agents, edges: edges})

    # Push hierarchy_data for collapsible tree (all-projects scope)
    hierarchy = GraphBuilder.build_hierarchy(graph_agents, scope: :all_projects)
    push_event(socket, "hierarchy_data", %{tree: hierarchy})
  end

  defp update_widget(widgets, id, fun) do
    case Map.get(widgets, id) do
      nil -> widgets
      widget -> Map.put(widgets, id, fun.(widget))
    end
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

  defp visible_agents(agents, nil), do: agents
  defp visible_agents(agents, project) do
    Enum.filter(agents, fn a ->
      (a[:project_name] == project) or
      (get_in(a, [:metadata, "project"]) == project)
    end)
  end

  defp widget_height(%{height: nil}), do: ""
  defp widget_height(%{height: h}), do: "height: #{h}px; overflow-y: auto;"

  defp count_sessions(config) do
    config
    |> Map.get("projects", [])
    |> Enum.flat_map(&Map.get(&1, "sessions", []))
    |> length()
  end

  defp recent_sessions(config) do
    config
    |> Map.get("projects", [])
    |> Enum.flat_map(fn p ->
      p
      |> Map.get("sessions", [])
      |> Enum.map(fn s ->
        %{
          project: p["name"],
          id: s["session_id"] || "",
          time: format_start_time(s["start_time"])
        }
      end)
    end)
    |> Enum.sort_by(& &1.time, :desc)
    |> Enum.take(20)
  end

  defp format_start_time(nil), do: "—"
  defp format_start_time(""), do: "—"
  defp format_start_time(t) do
    case DateTime.from_iso8601(t) do
      {:ok, dt, _} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)
        cond do
          diff < 60   -> "#{diff}s ago"
          diff < 3600 -> "#{div(diff, 60)}m ago"
          true        -> "#{div(diff, 3600)}h ago"
        end
      _ -> String.slice(t, 0, 10)
    end
  end

  defp ralph_summary(nil), do: ""
  defp ralph_summary(""), do: ""
  defp ralph_summary(path) do
    case Ralph.load(path) do
      {:ok, %{total: t, passed: p}} when t > 0 -> "#{p}/#{t}"
      _ -> ""
    end
  end

  defp ralph_progress(nil), do: 0
  defp ralph_progress(""), do: 0
  defp ralph_progress(path) do
    case Ralph.load(path) do
      {:ok, %{total: t, passed: p}} when t > 0 -> trunc(p / t * 100)
      _ -> 0
    end
  end

  defp format_seen(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)
        cond do
          diff < 60   -> "#{diff}s"
          diff < 3600 -> "#{div(diff, 60)}m"
          true        -> "#{div(diff, 3600)}h"
        end
      _ -> "—"
    end
  end
  defp format_seen(_), do: "—"

  defp format_notif_time(n) do
    case Map.get(n, :timestamp) do
      nil -> ""
      ts  -> format_seen(ts)
    end
  end

  defp safe_config do
    try do
      ConfigLoader.get_config()
    catch
      :exit, _ -> %{"projects" => [], "active_project" => nil}
    end
  end

  defp uptime do
    start = Application.get_env(:apm_v4, :server_start_time, System.system_time(:second))
    diff = System.system_time(:second) - start
    h = div(diff, 3600)
    m = div(rem(diff, 3600), 60)
    "#{String.pad_leading(to_string(h), 2, "0")}:#{String.pad_leading(to_string(m), 2, "0")}"
  end

  defp status_class("active"),     do: "badge-success"
  defp status_class("idle"),       do: "badge-ghost"
  defp status_class("error"),      do: "badge-error"
  defp status_class("discovered"), do: "badge-info"
  defp status_class("completed"),  do: "badge-accent"
  defp status_class(_),            do: "badge-ghost"

  defp tier_class(1), do: "badge-primary"
  defp tier_class(2), do: "badge-secondary"
  defp tier_class(3), do: "badge-warning"
  defp tier_class(_), do: "badge-ghost"

  defp notif_class("error"),   do: "badge-error"
  defp notif_class("warning"), do: "badge-warning"
  defp notif_class("success"), do: "badge-success"
  defp notif_class("info"),    do: "badge-info"
  defp notif_class(_),         do: "badge-ghost"

end
