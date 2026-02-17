defmodule ApmV4Web.DashboardLive do
  @moduledoc """
  LiveView dashboard for CCEM APM v4.

  Ported from the Python APM v3 embedded HTML dashboard to Phoenix LiveView
  with daisyUI components. Displays agent fleet status, stats cards, notification
  toasts, sidebar navigation, and multi-project support.
  """

  use ApmV4Web, :live_view

  import ApmV4Web.Accessibility

  alias ApmV4.AgentRegistry
  alias ApmV4.ConfigLoader
  alias ApmV4.ProjectStore
  alias ApmV4.Ralph

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:agents")
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:notifications")
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:config")
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:tasks")
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:commands")
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
    session_count = count_config_sessions(config)

    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> assign(:projects, projects)
      |> assign(:active_project, active_project)
      |> assign(:agents, agents)
      |> assign(:notifications, notifications)
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
      |> assign(:graph_expanded, false)
      |> assign(:show_anon, false)
      # Global filter bar state (Splunk/ELK-style)
      |> assign(:filter_status, nil)
      |> assign(:filter_namespace, nil)
      |> assign(:filter_agent_type, nil)
      |> assign(:filter_query, "")
      |> push_graph_data(agents)

    {:ok, socket}
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
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <%!-- Sidebar --%>
      <aside class="w-56 bg-base-200 border-r border-base-300 flex flex-col flex-shrink-0">
        <div class="p-4 border-b border-base-300">
          <h1 class="text-lg font-bold text-primary flex items-center gap-2">
            <span class="inline-block w-2 h-2 rounded-full bg-success animate-pulse"></span>
            CCEM APM v4
          </h1>
          <p class="text-xs text-base-content/50 mt-1">Agent Performance Monitor</p>
        </div>
        <nav class="flex-1 p-2 space-y-1">
          <.nav_item icon="hero-squares-2x2" label="Dashboard" active={@active_nav == :dashboard} href="/" />
          <.nav_item icon="hero-globe-alt" label="All Projects" active={@active_nav == :all} href="/apm-all" />
          <.nav_item icon="hero-arrow-path" label="Ralph" active={@active_nav == :ralph} href="/ralph" />
        </nav>
        <div class="p-3 border-t border-base-300">
          <div class="text-xs text-base-content/40">
            <div>Phoenix {Application.spec(:phoenix, :vsn)}</div>
            <div>Uptime: {@uptime}</div>
          </div>
        </div>
      </aside>

      <%!-- Main content --%>
      <div id="main-content" class="flex-1 flex flex-col overflow-hidden">
        <%!-- Top bar --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Dashboard</h2>
            <div class="badge badge-sm badge-ghost">
              {@agent_count} agents
            </div>
            <%!-- Project selector --%>
            <div :if={length(@projects) > 0} class="dropdown dropdown-bottom">
              <div tabindex="0" role="button" class="btn btn-ghost btn-xs gap-1">
                <.icon name="hero-folder" class="size-3" />
                {@active_project || "All Projects"}
                <.icon name="hero-chevron-down" class="size-3" />
              </div>
              <ul tabindex="0" class="dropdown-content z-50 menu menu-xs p-1 bg-base-200 border border-base-300 rounded-box shadow-lg w-48">
                <li>
                  <button phx-click="switch_project" phx-value-project="">
                    All Projects
                  </button>
                </li>
                <li :for={project <- @projects}>
                  <button
                    phx-click="switch_project"
                    phx-value-project={project["name"]}
                    class={@active_project == project["name"] && "active"}
                  >
                    {project["name"]}
                  </button>
                </li>
              </ul>
            </div>
          </div>
          <div class="flex items-center gap-3">
            <span class="text-xs text-base-content/50" id="clock" phx-hook="Clock">
              --:--:--
            </span>
            <div class="badge badge-sm badge-success gap-1">
              <span class="inline-block w-1.5 h-1.5 rounded-full bg-success animate-pulse"></span>
              LIVE
            </div>
            <%!-- Notification bell --%>
            <div class="dropdown dropdown-end">
              <div tabindex="0" role="button" class="btn btn-ghost btn-sm btn-circle indicator">
                <.icon name="hero-bell" class="size-4" />
                <span
                  :if={length(@notifications) > 0}
                  class="indicator-item badge badge-xs badge-error"
                >
                  {length(@notifications)}
                </span>
              </div>
              <div tabindex="0" class="dropdown-content z-50 w-80 mt-2">
                <div class="card bg-base-200 border border-base-300 shadow-xl">
                  <div class="card-body p-3">
                    <div class="flex justify-between items-center mb-2">
                      <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
                        Notifications
                      </h3>
                      <button class="text-xs text-primary hover:underline" phx-click="clear_notifications">
                        Clear all
                      </button>
                    </div>
                    <.live_region id="notification-list" politeness="polite">
                      <div class="space-y-1 max-h-64 overflow-y-auto">
                        <div
                          :for={notif <- Enum.take(@notifications, 10)}
                          class="p-2 rounded bg-base-300 text-xs"
                        >
                          <div class="flex items-center gap-2 mb-1">
                            <span class={["badge badge-xs", notif_badge_class(notif.level)]}>
                              {notif.level}
                            </span>
                            <span class="font-semibold truncate">{notif.title}</span>
                          </div>
                          <p class="text-base-content/60 truncate">{notif.message}</p>
                        </div>
                        <p :if={@notifications == []} class="text-center text-base-content/40 py-4">
                          No notifications
                        </p>
                      </div>
                    </.live_region>
                  </div>
                </div>
              </div>
            </div>
            <Layouts.theme_toggle />
          </div>
        </header>

        <%!-- Filter bar (Splunk/ELK-style global query) --%>
        <div class="bg-base-200 border-b border-base-300 px-4 py-1.5 flex items-center gap-2 flex-shrink-0">
          <.icon name="hero-funnel" class="size-3.5 text-base-content/40" />
          <input
            type="text"
            placeholder="Search agents by name, id, namespace..."
            value={@filter_query}
            phx-keyup="update_filter_query"
            phx-debounce="200"
            class="input input-xs input-bordered bg-base-300 w-48 text-xs"
          />
          <%!-- Status filter --%>
          <div class="dropdown dropdown-bottom">
            <div tabindex="0" role="button" class={["btn btn-xs gap-1", @filter_status && "btn-primary" || "btn-ghost"]}>
              {if @filter_status, do: @filter_status, else: "Status"}
              <.icon name="hero-chevron-down" class="size-2.5" />
            </div>
            <ul tabindex="0" class="dropdown-content z-50 menu menu-xs p-1 bg-base-200 border border-base-300 rounded-box shadow-lg w-32">
              <li><button phx-click="set_filter" phx-value-field="status" phx-value-value="">All</button></li>
              <li :for={s <- ["active", "idle", "error", "discovered", "completed"]}>
                <button phx-click="set_filter" phx-value-field="status" phx-value-value={s}>{s}</button>
              </li>
            </ul>
          </div>
          <%!-- Agent type filter --%>
          <div class="dropdown dropdown-bottom">
            <div tabindex="0" role="button" class={["btn btn-xs gap-1", @filter_agent_type && "btn-info" || "btn-ghost"]}>
              {if @filter_agent_type, do: @filter_agent_type, else: "Type"}
              <.icon name="hero-chevron-down" class="size-2.5" />
            </div>
            <ul tabindex="0" class="dropdown-content z-50 menu menu-xs p-1 bg-base-200 border border-base-300 rounded-box shadow-lg w-36">
              <li><button phx-click="set_filter" phx-value-field="agent_type" phx-value-value="">All</button></li>
              <li :for={t <- ["individual", "squadron", "swarm", "orchestrator"]}>
                <button phx-click="set_filter" phx-value-field="agent_type" phx-value-value={t}>{t}</button>
              </li>
            </ul>
          </div>
          <%!-- Namespace filter --%>
          <div :if={namespaces_from_agents(@agents) != []} class="dropdown dropdown-bottom">
            <div tabindex="0" role="button" class={["btn btn-xs gap-1", @filter_namespace && "btn-accent" || "btn-ghost"]}>
              {if @filter_namespace, do: @filter_namespace, else: "Namespace"}
              <.icon name="hero-chevron-down" class="size-2.5" />
            </div>
            <ul tabindex="0" class="dropdown-content z-50 menu menu-xs p-1 bg-base-200 border border-base-300 rounded-box shadow-lg w-44 max-h-48 overflow-y-auto">
              <li><button phx-click="set_filter" phx-value-field="namespace" phx-value-value="">All</button></li>
              <li :for={ns <- namespaces_from_agents(@agents)}>
                <button phx-click="set_filter" phx-value-field="namespace" phx-value-value={ns}>{ns}</button>
              </li>
            </ul>
          </div>
          <%!-- Show unnamed toggle --%>
          <label class="flex items-center gap-1 text-[10px] text-base-content/40 ml-auto cursor-pointer">
            <input type="checkbox" class="checkbox checkbox-xs" phx-click="toggle_show_anon" checked={@show_anon} />
            Show unnamed
          </label>
          <%!-- Clear filters --%>
          <button
            :if={@filter_status || @filter_namespace || @filter_agent_type || @filter_query != ""}
            class="btn btn-ghost btn-xs text-error"
            phx-click="clear_filters"
          >
            Clear
          </button>
        </div>

        <%!-- Dashboard body --%>
        <div class="flex-1 flex overflow-hidden">
          <%!-- Left panel: stats + agents --%>
          <div class="flex-1 overflow-y-auto p-4 space-y-4">
            <%!-- Stats grid --%>
            <.live_region id="agent-status-summary" politeness="polite">
              <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3">
                <.stat_card label="Agents" value={@agent_count} color="text-primary" />
                <.stat_card label="Active" value={@active_count} color="text-success" />
                <.stat_card label="Idle" value={@idle_count} color="text-base-content/60" />
                <.stat_card label="Errors" value={@error_count} color="text-error" />
                <.stat_card label="Sessions" value={@session_count} color="text-info" />
                <.stat_card label="Notifications" value={length(@notifications)} color="text-warning" />
              </div>
            </.live_region>

            <%!-- D3 Dependency Graph --%>
            <div class={[
              "card bg-base-200 border border-base-300 transition-all duration-200",
              @graph_expanded && "fixed inset-4 z-40 shadow-2xl"
            ]}>
              <div class="card-body p-3">
                <div class="flex items-center justify-between mb-2">
                  <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                    Dependency Graph
                  </h3>
                  <div class="flex items-center gap-3">
                    <%!-- Legend --%>
                    <div class="flex items-center gap-2 text-[9px] text-base-content/40">
                      <span class="flex items-center gap-0.5"><span class="inline-block w-2.5 h-2.5 rounded-full border-2 border-base-content/30"></span> agent</span>
                      <span class="flex items-center gap-0.5"><span class="inline-block w-3 h-3 rounded-full border-2 border-dashed border-info/60"></span> squadron</span>
                      <span class="flex items-center gap-0.5"><span class="inline-block w-3.5 h-3.5 rounded-full border-2 border-dotted border-warning/60"></span> swarm</span>
                      <span class="flex items-center gap-0.5"><span class="inline-block w-3 h-1.5 rounded bg-primary/20 border border-primary/50"></span> namespace</span>
                    </div>
                    <button
                      class="btn btn-ghost btn-xs"
                      phx-click="toggle_graph"
                      title={if @graph_expanded, do: "Collapse", else: "Expand"}
                    >
                      <.icon name={if @graph_expanded, do: "hero-arrows-pointing-in", else: "hero-arrows-pointing-out"} class="size-3" />
                    </button>
                  </div>
                </div>
                <div
                  id="dep-graph"
                  class={[
                    "w-full rounded bg-base-300 relative",
                    @graph_expanded && "h-[calc(100%-2rem)]" || "h-80"
                  ]}
                  phx-hook="DependencyGraph"
                  phx-update="ignore"
                >
                </div>
              </div>
            </div>

            <%!-- Agent Fleet --%>
            <div>
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-2">
                Agent Fleet
              </h3>
              <%!-- Column headers --%>
              <div class="grid grid-cols-[24px_1fr_80px_60px_80px] gap-2 px-3 mb-1 text-[10px] uppercase tracking-wider text-base-content/30">
                <span></span>
                <span>Agent</span>
                <span class="text-right">Last Seen</span>
                <span class="text-center">Type</span>
                <span class="text-center">Status</span>
              </div>
              <%!-- Agent rows --%>
              <div class="space-y-1">
                <div
                  :for={agent <- filtered_agents(assigns)}
                  class="card bg-base-200 border border-base-300 hover:border-primary/50 transition-colors cursor-pointer"
                  phx-click="select_agent"
                  phx-value-agent_id={agent.id}
                >
                  <div class="grid grid-cols-[24px_1fr_80px_60px_80px] gap-2 items-center px-3 py-2">
                    <div class={["badge badge-xs", tier_badge_class(agent.tier)]}>
                      {agent.tier}
                    </div>
                    <div>
                      <div class="text-sm font-medium truncate flex items-center gap-1.5">
                        {agent.name}
                        <span :if={agent[:member_count] && agent[:member_count] > 1} class="badge badge-xs badge-info">
                          {agent[:member_count]}
                        </span>
                      </div>
                      <div class="text-[10px] text-base-content/30 flex items-center gap-1">
                        <span class="font-mono">{agent.id}</span>
                        <span :if={agent[:namespace]} class="text-primary/60">/ {agent[:namespace]}</span>
                      </div>
                    </div>
                    <div class="text-right text-xs text-base-content/40">
                      {format_last_seen(agent.last_seen)}
                    </div>
                    <div class="text-center">
                      <span class={["badge badge-xs", agent_type_badge_class(agent[:agent_type])]}>
                        {agent[:agent_type] || "individual"}
                      </span>
                    </div>
                    <div class="text-center">
                      <span class={["badge badge-sm", status_badge_class(agent.status)]}>
                        {agent.status}
                      </span>
                    </div>
                  </div>
                </div>
                <div :if={@agents == []} class="text-center text-base-content/30 py-8 text-sm">
                  No agents registered. POST to /api/register to add agents.
                </div>
              </div>
            </div>
          </div>

          <%!-- Right panel: tabs --%>
          <div class="w-80 border-l border-base-300 bg-base-200 flex flex-col flex-shrink-0">
            <div role="tablist" class="tabs tabs-border bg-base-300">
              <button
                :for={tab <- [:inspector, :ralph, :commands, :todos]}
                role="tab"
                class={["tab tab-sm", @active_tab == tab && "tab-active"]}
                phx-click="switch_tab"
                phx-value-tab={tab}
              >
                {tab_label(tab)}
              </button>
            </div>

            <div class="flex-1 overflow-y-auto p-3">
              <%!-- Inspector tab --%>
              <div :if={@active_tab == :inspector}>
                <div :if={@selected_agent == nil} class="text-center text-base-content/30 py-8 text-xs">
                  Click an agent or graph node to inspect
                </div>
                <div :if={@selected_agent} class="space-y-3">
                  <h3 class="text-sm font-semibold">{@selected_agent.name}</h3>
                  <div class="space-y-1 text-xs">
                    <div class="flex justify-between">
                      <span class="text-base-content/50">ID</span>
                      <span class="font-mono">{@selected_agent.id}</span>
                    </div>
                    <div class="flex justify-between">
                      <span class="text-base-content/50">Tier</span>
                      <span>{@selected_agent.tier}</span>
                    </div>
                    <div class="flex justify-between">
                      <span class="text-base-content/50">Status</span>
                      <span class={["badge badge-xs", status_badge_class(@selected_agent.status)]}>
                        {@selected_agent.status}
                      </span>
                    </div>
                    <div class="flex justify-between">
                      <span class="text-base-content/50">Type</span>
                      <span class={["badge badge-xs", agent_type_badge_class(@selected_agent[:agent_type])]}>
                        {@selected_agent[:agent_type] || "individual"}
                      </span>
                    </div>
                    <div :if={@selected_agent[:member_count]} class="flex justify-between">
                      <span class="text-base-content/50">Members</span>
                      <span class="badge badge-xs badge-info">{@selected_agent[:member_count]} agents</span>
                    </div>
                    <div :if={@selected_agent[:namespace]} class="flex justify-between">
                      <span class="text-base-content/50">Namespace</span>
                      <span class="text-primary">{@selected_agent[:namespace]}</span>
                    </div>
                    <div :if={@selected_agent[:project_name]} class="flex justify-between">
                      <span class="text-base-content/50">Project</span>
                      <span>{@selected_agent.project_name}</span>
                    </div>
                    <div :if={@selected_agent[:path]} class="flex justify-between">
                      <span class="text-base-content/50">Path</span>
                      <span class="font-mono text-[10px] truncate max-w-[160px]" title={@selected_agent[:path]}>
                        {Path.basename(@selected_agent[:path] || "")}
                      </span>
                    </div>
                    <div class="flex justify-between">
                      <span class="text-base-content/50">Last Seen</span>
                      <span>{format_last_seen(@selected_agent.last_seen)}</span>
                    </div>
                    <div :if={@selected_agent.deps != []} class="pt-1">
                      <span class="text-base-content/50">Dependencies:</span>
                      <div class="flex flex-wrap gap-1 mt-1">
                        <span :for={dep <- @selected_agent.deps} class="badge badge-xs badge-ghost">
                          {dep}
                        </span>
                      </div>
                    </div>
                  </div>
                </div>
              </div>

              <%!-- Ralph tab --%>
              <div :if={@active_tab == :ralph} class="space-y-2">
                <div class="flex items-center justify-between">
                  <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                    Ralph
                  </h3>
                  <div class="flex items-center gap-2">
                    <span class="text-[10px] text-base-content/30">
                      {@ralph_data.passed}/{@ralph_data.total} passed
                    </span>
                    <a href="/ralph" class="text-[10px] text-primary hover:underline">flowchart →</a>
                  </div>
                </div>

                <%!-- Progress bar --%>
                <div :if={@ralph_data.total > 0} class="w-full bg-base-300 rounded-full h-1">
                  <div
                    class="bg-success h-1 rounded-full transition-all"
                    style={"width: #{trunc(@ralph_data.passed / @ralph_data.total * 100)}%"}
                  ></div>
                </div>

                <%!-- Story list --%>
                <div :if={@ralph_data.total > 0} class="space-y-0.5 max-h-80 overflow-y-auto">
                  <div
                    :for={story <- @ralph_data.stories}
                    class="flex items-center gap-2 px-1.5 py-1 rounded hover:bg-base-300 text-xs cursor-default group"
                  >
                    <span class={[
                      "w-2 h-2 rounded-full flex-shrink-0",
                      story["passes"] == true && "bg-success" || "bg-error/60"
                    ]}>
                    </span>
                    <span class="truncate flex-1 group-hover:text-base-content text-base-content/70">
                      {story["title"] || story["id"]}
                    </span>
                    <span class="text-base-content/30 flex-shrink-0 text-[10px]">
                      #{story["priority"] || ""}
                    </span>
                  </div>
                </div>

                <%!-- No prd.json --%>
                <div :if={@ralph_data.total == 0} class="text-xs text-base-content/40 py-4 text-center">
                  No prd.json for this project.
                  <a href="/ralph" class="text-primary hover:underline block mt-1">
                    Open flowchart →
                  </a>
                </div>
              </div>

              <%!-- Commands tab --%>
              <div :if={@active_tab == :commands} class="space-y-2">
                <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                  Slash Commands
                </h3>
                <div :if={@commands == []} class="text-xs text-base-content/40">
                  No commands registered. POST to /api/commands to add.
                </div>
                <div :for={cmd <- @commands} class="p-2 rounded bg-base-300 text-xs">
                  <div class="font-semibold">/{cmd["name"] || cmd[:name]}</div>
                  <div class="text-base-content/50">{cmd["description"] || cmd[:description]}</div>
                </div>
              </div>

              <%!-- TODOs tab --%>
              <div :if={@active_tab == :todos} class="space-y-2">
                <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                  Active Tasks
                </h3>
                <div :if={@tasks == []} class="text-xs text-base-content/40">
                  No tasks synced. POST to /api/tasks/sync to add.
                </div>
                <div :for={task <- @tasks} class="p-2 rounded bg-base-300 text-xs">
                  <div class="flex items-center gap-2">
                    <span class={["badge badge-xs", task_status_class(task["status"] || task[:status])]}>
                      {task["status"] || task[:status] || "pending"}
                    </span>
                    <span class="font-medium">{task["subject"] || task[:subject] || task["title"] || "Task"}</span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  def handle_event("toggle_graph", _params, socket) do
    {:noreply, assign(socket, :graph_expanded, !socket.assigns.graph_expanded)}
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

  def handle_event("select_agent", %{"agent_id" => agent_id}, socket) do
    agent = AgentRegistry.get_agent(agent_id)

    socket =
      if agent do
        socket
        |> assign(:active_tab, :inspector)
        |> assign(:selected_agent, agent)
      else
        socket
      end

    {:noreply, socket}
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

  def handle_event("graph_anon_toggled", %{"show" => show}, socket) do
    {:noreply, assign(socket, :show_anon, show)}
  end

  # --- PubSub Handlers ---

  @impl true
  def handle_info({:agent_registered, _agent}, socket) do
    refresh_agents(socket)
  end

  def handle_info({:agent_updated, _agent}, socket) do
    refresh_agents(socket)
  end

  def handle_info({:agent_discovered, _agent_id, _project}, socket) do
    refresh_agents(socket)
  end

  def handle_info({:notification_added, _notif}, socket) do
    notifications = AgentRegistry.get_notifications()
    {:noreply, assign(socket, :notifications, notifications)}
  end

  def handle_info(:notifications_read, socket) do
    notifications = AgentRegistry.get_notifications()
    {:noreply, assign(socket, :notifications, notifications)}
  end

  def handle_info({:config_reloaded, config}, socket) do
    projects = Map.get(config, "projects", [])
    active = Map.get(config, "active_project")
    ralph_data = load_ralph_for_project(active, config)
    session_count = count_config_sessions(config)

    socket =
      socket
      |> assign(:projects, projects)
      |> assign(:active_project, active)
      |> assign(:ralph_data, ralph_data)
      |> assign(:session_count, session_count)

    refresh_agents(socket)
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

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp refresh_agents(socket) do
    project = socket.assigns.active_project
    agents = AgentRegistry.list_agents(project)

    socket =
      socket
      |> assign(:agents, agents)
      |> update_agent_counts(agents)
      |> push_graph_data(agents)

    {:noreply, socket}
  end

  defp update_agent_counts(socket, agents) do
    socket
    |> assign(:agent_count, length(agents))
    |> assign(:active_count, Enum.count(agents, &(&1.status == "active")))
    |> assign(:idle_count, Enum.count(agents, &(&1.status == "idle")))
    |> assign(:error_count, Enum.count(agents, &(&1.status == "error")))
  end

  # --- Helper Components ---

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :href, :string, required: true

  defp nav_item(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "flex items-center gap-3 px-3 py-2 rounded text-sm transition-colors",
        @active && "bg-primary/10 text-primary font-medium",
        !@active && "text-base-content/60 hover:text-base-content hover:bg-base-300"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
    </a>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :color, :string, default: "text-primary"

  defp stat_card(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body p-3 items-center text-center">
        <div class={["text-2xl font-bold tabular-nums", @color]}>{@value}</div>
        <div class="text-[10px] uppercase tracking-widest text-base-content/40">{@label}</div>
      </div>
    </div>
    """
  end

  # --- Private Helpers ---

  defp filtered_agents(assigns) do
    assigns.agents
    |> filter_by_status(assigns[:filter_status])
    |> filter_by_namespace(assigns[:filter_namespace])
    |> filter_by_agent_type(assigns[:filter_agent_type])
    |> filter_by_query(assigns[:filter_query])
  end

  defp push_filtered_graph(socket) do
    filtered = filtered_agents(socket.assigns)
    push_graph_data(socket, filtered)
  end

  defp namespaces_from_agents(agents) do
    agents
    |> Enum.map(& &1[:namespace])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
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

    push_event(socket, "agents_updated", %{agents: graph_agents, edges: edges})
  end

  defp calculate_uptime do
    start_time = Application.get_env(:apm_v4, :server_start_time, System.system_time(:second))
    seconds = System.system_time(:second) - start_time
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)
    "#{String.pad_leading(to_string(hours), 2, "0")}:#{String.pad_leading(to_string(minutes), 2, "0")}:#{String.pad_leading(to_string(secs), 2, "0")}"
  end

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

  defp status_badge_class("active"), do: "badge-success"
  defp status_badge_class("idle"), do: "badge-ghost"
  defp status_badge_class("error"), do: "badge-error"
  defp status_badge_class("discovered"), do: "badge-info"
  defp status_badge_class("completed"), do: "badge-accent"
  defp status_badge_class(_), do: "badge-ghost"

  defp agent_type_badge_class("squadron"), do: "badge-info"
  defp agent_type_badge_class("swarm"), do: "badge-warning"
  defp agent_type_badge_class("orchestrator"), do: "badge-accent"
  defp agent_type_badge_class(_), do: "badge-ghost"

  defp tier_badge_class(1), do: "badge-primary"
  defp tier_badge_class(2), do: "badge-secondary"
  defp tier_badge_class(3), do: "badge-warning"
  defp tier_badge_class(_), do: "badge-ghost"

  defp notif_badge_class("error"), do: "badge-error"
  defp notif_badge_class("warning"), do: "badge-warning"
  defp notif_badge_class("success"), do: "badge-success"
  defp notif_badge_class("info"), do: "badge-info"
  defp notif_badge_class(_), do: "badge-ghost"

  defp task_status_class("completed"), do: "badge-success"
  defp task_status_class("in_progress"), do: "badge-info"
  defp task_status_class("pending"), do: "badge-ghost"
  defp task_status_class(_), do: "badge-ghost"

  defp tab_label(:inspector), do: "Inspector"
  defp tab_label(:ralph), do: "Ralph"
  defp tab_label(:commands), do: "Commands"
  defp tab_label(:todos), do: "TODOs"

  defp load_ralph_for_project(project_name, config) do
    prd_path =
      if project_name do
        config
        |> Map.get("projects", [])
        |> Enum.find(fn p -> p["name"] == project_name end)
        |> then(fn
          nil -> nil
          project -> project["prd_json"]
        end)
      end

    case Ralph.load(prd_path) do
      {:ok, data} -> data
      _ -> %{project: "", branch: "", description: "", stories: [], total: 0, passed: 0}
    end
  end

  defp count_config_sessions(config) do
    config
    |> Map.get("projects", [])
    |> Enum.flat_map(fn p -> Map.get(p, "sessions", []) end)
    |> length()
  end

  defp safe_get_config do
    try do
      ConfigLoader.get_config()
    catch
      :exit, _ -> %{"projects" => [], "active_project" => nil}
    end
  end
end
