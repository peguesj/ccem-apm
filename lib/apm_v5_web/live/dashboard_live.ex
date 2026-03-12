defmodule ApmV5Web.DashboardLive do
  @moduledoc """
  LiveView dashboard for CCEM APM v4.

  Ported from the Python APM v3 embedded HTML dashboard to Phoenix LiveView
  with daisyUI components. Displays agent fleet status, stats cards, notification
  toasts, sidebar navigation, and multi-project support.
  """

  use ApmV5Web, :live_view

  import ApmV5Web.Accessibility

  alias ApmV5.AgentRegistry
  alias ApmV5.ConfigLoader
  alias ApmV5.DashboardStore
  alias ApmV5.ProjectStore
  alias ApmV5.Ralph
  alias ApmV5.UpmStore
  alias ApmV5.PortManager
  alias ApmV5.GraphBuilder
  alias ApmV5.ChatStore

  import ApmV5Web.Components.GettingStartedShowcase

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:agents")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:notifications")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:config")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:tasks")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:commands")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:upm")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:ports")
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
    upm_status = UpmStore.get_status()
    project_configs = PortManager.get_project_configs()
    port_clashes = PortManager.detect_clashes()
    port_ranges = PortManager.get_port_ranges()

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
      |> assign(:active_skill_count, skill_count())
      |> assign(:upm_status, upm_status)
      |> assign(:project_configs, project_configs)
      |> assign(:port_clashes, port_clashes)
      |> assign(:port_ranges, port_ranges)
      |> assign(:port_remediation, nil)
      |> assign(:graph_expanded, false)
      |> assign(:graph_view, :graph)
      |> assign(:show_anon, false)
      |> assign(:list_expanded_nodes, MapSet.new(["root"]))
      |> assign(:hierarchy, nil)
      |> assign(:chat_scope, "global")
      |> assign(:chat_messages, [])
      |> assign(:chat_input, "")
      |> assign(:show_showcase, true)
      |> assign(:saved_layouts, DashboardStore.list_layouts())
      |> assign(:saved_presets, DashboardStore.list_presets())
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
          <p class="text-xs text-base-content/50 mt-1">
            {length(@projects)} projects · {@active_count} active
          </p>
        </div>
        <nav class="flex-1 p-2 space-y-1 overflow-y-auto">
          <.nav_item icon="hero-squares-2x2" label="Dashboard" active={@active_nav == :dashboard} href="/" />
          <.nav_item icon="hero-globe-alt" label="All Projects" active={@active_nav == :all} href="/apm-all" />
          <.nav_item icon="hero-rectangle-group" label="Formations" active={false} href="/formation" />
          <.nav_item icon="hero-clock" label="Timeline" active={@active_nav == :timeline} href="/timeline" />
          <.nav_item icon="hero-bell" label="Notifications" active={false} href="/notifications" />
          <.nav_item icon="hero-queue-list" label="Background Tasks" active={false} href="/tasks" />
          <.nav_item icon="hero-magnifying-glass" label="Project Scanner" active={false} href="/scanner" />
          <.nav_item icon="hero-bolt" label="Actions" active={false} href="/actions" />
          <.nav_item icon="hero-sparkles" label="Skills" active={@active_nav == :skills} href="/skills" badge={@active_skill_count} />
          <.nav_item icon="hero-arrow-path" label="Ralph" active={@active_nav == :ralph} href="/ralph" />
          <button
            phx-click="switch_tab"
            phx-value-tab="ports"
            class={[
              "flex items-center gap-3 px-3 py-2 rounded text-sm transition-colors w-full text-left",
              @active_tab == :ports && "bg-primary/10 text-primary font-medium",
              @active_tab != :ports && "text-base-content/60 hover:text-base-content hover:bg-base-300"
            ]}
          >
            <.icon name="hero-signal" class="size-4" />
            Ports
            <span :if={length(@port_clashes) > 0} class="badge badge-xs badge-error ml-auto">{length(@port_clashes)}</span>
          </button>
          <.nav_item icon="hero-book-open" label="Docs" active={@active_nav == :docs} href="/docs" />
        </nav>
        <div class="p-3 border-t border-base-300 space-y-2">
          <button
            phx-click="showcase:show"
            class="flex items-center gap-2 text-xs text-base-content/40 hover:text-primary transition-colors w-full"
          >
            <.icon name="hero-sparkles" class="size-3" />
            Getting Started
          </button>
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
            <%!-- Layout picker --%>
            <div class="dropdown dropdown-bottom">
              <div tabindex="0" role="button" class="btn btn-ghost btn-xs gap-1">
                <.icon name="hero-squares-2x2" class="size-3" />
                Layouts
                <.icon name="hero-chevron-down" class="size-3" />
              </div>
              <ul tabindex="0" class="dropdown-content z-50 menu menu-xs p-1 bg-base-200 border border-base-300 rounded-box shadow-lg w-48">
                <li :for={layout <- @saved_layouts}>
                  <button phx-click="load_layout" phx-value-id={layout["id"]}>
                    {layout["name"]}
                  </button>
                </li>
                <li :if={@saved_layouts == []}>
                  <span class="text-base-content/40">No saved layouts</span>
                </li>
              </ul>
            </div>
            <%!-- Save buttons --%>
            <button class="btn btn-ghost btn-xs gap-1" phx-click="save_layout" phx-value-name="Quick Save">
              <.icon name="hero-bookmark" class="size-3" />
              Save Layout
            </button>
            <button class="btn btn-ghost btn-xs gap-1" phx-click="save_filter_preset" phx-value-name="Quick Filters">
              <.icon name="hero-funnel" class="size-3" />
              Save Filters
            </button>
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
                  :if={Enum.any?(@notifications, &(!&1.read))}
                  class="indicator-item badge badge-xs badge-error"
                >
                  {Enum.count(@notifications, &(!&1.read))}
                </span>
              </div>
              <div tabindex="0" class="dropdown-content z-50 w-96 mt-2">
                <div class="card bg-base-200 border border-base-300 shadow-xl">
                  <div class="card-body p-0">
                    <%!-- Header --%>
                    <div class="flex justify-between items-center px-3 pt-3 pb-2 border-b border-base-300">
                      <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
                        Notifications
                        <span :if={length(@notifications) > 0} class="ml-1 text-base-content/40 font-normal normal-case">
                          ({length(@notifications)})
                        </span>
                      </h3>
                      <div class="flex items-center gap-2">
                        <button
                          class="text-xs text-primary hover:underline"
                          phx-click="mark_all_read"
                        >
                          Mark read
                        </button>
                        <span class="text-base-content/20">·</span>
                        <button
                          class="text-xs text-error/70 hover:text-error hover:underline"
                          phx-click="clear_notifications"
                        >
                          Clear all
                        </button>
                      </div>
                    </div>
                    <%!-- Notification list --%>
                    <.live_region id="notification-list" politeness="polite">
                      <div class="space-y-0 max-h-96 overflow-y-auto divide-y divide-base-300">
                        <div
                          :for={notif <- Enum.take(@notifications, 15)}
                          class={["p-3 text-xs transition-colors hover:bg-base-300/50", if(!notif.read, do: "bg-base-300/30 border-l-2 border-primary", else: "")]}
                        >
                          <div class="flex items-start gap-2">
                            <span class={["badge badge-xs mt-0.5 flex-shrink-0", notif_badge_class(notif[:type] || notif[:level])]}>
                              {notif[:type] || notif[:level] || "info"}
                            </span>
                            <div class="flex-1 min-w-0">
                              <div class="font-semibold truncate">{notif[:title]}</div>
                              <p class="text-base-content/60 mt-0.5 leading-snug">{notif[:message]}</p>
                              <%!-- Contextual metadata --%>
                              <div class="flex flex-wrap gap-x-3 gap-y-0.5 mt-1 text-[10px] text-base-content/40">
                                <span :if={notif[:category]}><%= notif[:category] %></span>
                                <span :if={notif[:project_name]}><%= notif[:project_name] %></span>
                                <span :if={notif[:formation_id]}>fmt: {notif[:formation_id]}</span>
                                <span :if={notif[:agent_id]}>agent: {notif[:agent_id]}</span>
                              </div>
                              <%!-- Action buttons --%>
                              <div class="flex items-center gap-2 mt-2">
                                <%= if notif[:formation_id] do %>
                                  <.link
                                    href="/formation"
                                    class="btn btn-xs btn-ghost text-[10px] px-1.5 py-0.5 h-auto min-h-0 border border-base-content/20"
                                  >
                                    View Formation
                                  </.link>
                                <% end %>
                                <%= if notif[:agent_id] do %>
                                  <button
                                    phx-click="select_agent"
                                    phx-value-id={notif[:agent_id]}
                                    class="btn btn-xs btn-ghost text-[10px] px-1.5 py-0.5 h-auto min-h-0 border border-base-content/20"
                                  >
                                    Inspect Agent
                                  </button>
                                <% end %>
                                <%= if notif[:category] in ["upm", "formation"] do %>
                                  <.link
                                    href="/workflow/upm"
                                    class="btn btn-xs btn-ghost text-[10px] px-1.5 py-0.5 h-auto min-h-0 border border-base-content/20"
                                  >
                                    UPM Flow
                                  </.link>
                                <% end %>
                                <button
                                  phx-click="dismiss_notification"
                                  phx-value-id={notif[:id]}
                                  class="ml-auto text-[10px] text-base-content/30 hover:text-base-content/60"
                                >
                                  ✕
                                </button>
                              </div>
                            </div>
                          </div>
                        </div>
                        <p :if={@notifications == []} class="text-center text-base-content/40 py-6 text-xs">
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

            <%!-- UPM Execution Panel --%>
            <div :if={@upm_status.active} class="card bg-base-200 border border-base-300">
              <div class="card-body p-3">
                <div class="flex items-center justify-between mb-2">
                  <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                    UPM Execution
                  </h3>
                  <span class={["badge badge-sm", upm_status_badge(@upm_status.session.status)]}>
                    {@upm_status.session.status}
                  </span>
                </div>
                <%!-- Wave progress --%>
                <div class="flex items-center gap-2 mb-2">
                  <span class="text-xs text-base-content/60">
                    Wave {@upm_status.session.current_wave}/{@upm_status.session.total_waves}
                  </span>
                  <div class="flex-1 bg-base-300 rounded-full h-1.5">
                    <div
                      class="bg-primary h-1.5 rounded-full transition-all"
                      style={"width: #{if @upm_status.session.total_waves > 0, do: trunc(@upm_status.session.current_wave / @upm_status.session.total_waves * 100), else: 0}%"}
                    ></div>
                  </div>
                  <span class="text-[10px] text-base-content/40">
                    {upm_story_summary(@upm_status.session.stories)}
                  </span>
                </div>
                <%!-- Story list --%>
                <div class="space-y-0.5 max-h-32 overflow-y-auto">
                  <div
                    :for={story <- @upm_status.session.stories}
                    class="flex items-center gap-2 px-1.5 py-0.5 rounded text-xs hover:bg-base-300"
                  >
                    <span class={["w-2 h-2 rounded-full flex-shrink-0", upm_story_dot(story.status)]}></span>
                    <span class="font-mono text-[10px] text-base-content/50">{story.id}</span>
                    <span class="truncate flex-1 text-base-content/70">{story[:title] || ""}</span>
                    <span :if={story.agent_id} class="badge badge-xs badge-ghost font-mono">{story.agent_id}</span>
                  </div>
                </div>
                <%!-- Recent events --%>
                <div :if={@upm_status.events != []} class="mt-2 border-t border-base-300 pt-2">
                  <div class="text-[10px] text-base-content/40 uppercase tracking-wider mb-1">Events</div>
                  <div class="space-y-0.5 max-h-20 overflow-y-auto">
                    <div :for={event <- Enum.take(Enum.reverse(@upm_status.events), 5)} class="text-[10px] text-base-content/50 flex gap-2">
                      <span class="text-base-content/30">{format_event_time(event.timestamp)}</span>
                      <span class={["font-medium", upm_event_color(event.event_type)]}>{event.event_type}</span>
                      <span :if={event.data["story_id"]} class="font-mono">{event.data["story_id"]}</span>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Port Overview --%>
            <div :if={@project_configs != %{}} class="card bg-base-200 border border-base-300">
              <div class="card-body p-3">
                <div class="flex items-center justify-between mb-2">
                  <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                    Port Allocations
                  </h3>
                  <div class="flex items-center gap-2">
                    <span class="text-[10px] text-base-content/40">{map_size(@project_configs)} projects</span>
                    <span :if={@port_clashes != []} class="badge badge-xs badge-error">{length(@port_clashes)} clashes</span>
                    <button phx-click="scan_ports" class="btn btn-ghost btn-xs" title="Rescan">
                      <.icon name="hero-arrow-path" class="size-3" />
                    </button>
                    <button phx-click="switch_tab" phx-value-tab="ports" class="btn btn-ghost btn-xs text-primary" title="Details">
                      <.icon name="hero-arrow-top-right-on-square" class="size-3" />
                    </button>
                  </div>
                </div>
                <%!-- Compact port grid --%>
                <div class="flex flex-wrap gap-1.5">
                  <div
                    :for={{name, config} <- Enum.sort_by(@project_configs, fn {n, _} -> n end)}
                    :if={config.ports != []}
                    class="flex items-center gap-1 px-2 py-1 rounded bg-base-300 text-[10px]"
                  >
                    <span class="font-medium text-base-content/70">{name}</span>
                    <span :for={port_info <- config.ports} class="flex items-center gap-0.5">
                      <span class={["w-1.5 h-1.5 rounded-full", if(port_info[:active], do: "bg-success", else: "bg-base-content/20")]}></span>
                      <span class="font-mono text-base-content/50">:{port_info.port}</span>
                    </span>
                  </div>
                </div>
                <%!-- Clash alerts inline --%>
                <div :if={@port_clashes != []} class="mt-2 space-y-1">
                  <div :for={clash <- @port_clashes} class="flex items-center gap-2 px-2 py-1 rounded bg-error/10 text-[10px]">
                    <.icon name="hero-exclamation-triangle" class="size-3 text-error" />
                    <span class="font-mono text-error">:{clash.port}</span>
                    <span class="text-base-content/50">{Enum.join(clash.projects, " + ")}</span>
                    <button phx-click="get_remediation" phx-value-port={clash.port}
                      class="ml-auto text-primary hover:underline">fix</button>
                  </div>
                </div>
              </div>
            </div>

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
                  <div class="flex items-center gap-2">
                    <%!-- Graph/List pill toggle --%>
                    <div class="flex items-center gap-0.5 bg-base-300 rounded-full p-0.5">
                      <button
                        phx-click="set_graph_view"
                        phx-value-view="graph"
                        class={["px-2.5 py-0.5 rounded-full text-[10px] font-medium transition-colors", if(@graph_view == :graph, do: "bg-base-100 shadow-sm text-base-content", else: "text-base-content/40 hover:text-base-content")]}
                      >Graph</button>
                      <button
                        phx-click="set_graph_view"
                        phx-value-view="list"
                        class={["px-2.5 py-0.5 rounded-full text-[10px] font-medium transition-colors", if(@graph_view == :list, do: "bg-base-100 shadow-sm text-base-content", else: "text-base-content/40 hover:text-base-content")]}
                      >List</button>
                    </div>
                    <%!-- Legend (graph only) --%>
                    <%= if @graph_view == :graph do %>
                      <div class="flex items-center gap-2 text-[9px] text-base-content/40">
                        <span class="flex items-center gap-0.5"><span class="inline-block w-2.5 h-2.5 rounded-full border-2 border-base-content/30"></span> agent</span>
                        <span class="flex items-center gap-0.5"><span class="inline-block w-3 h-3 rounded-full border-2 border-dashed border-info/60"></span> squadron</span>
                        <span class="flex items-center gap-0.5"><span class="inline-block w-3.5 h-3.5 rounded-full border-2 border-dotted border-warning/60"></span> swarm</span>
                        <span class="flex items-center gap-0.5"><span class="inline-block w-3 h-1.5 rounded bg-primary/20 border border-primary/50"></span> namespace</span>
                      </div>
                    <% end %>
                    <button
                      class="btn btn-ghost btn-xs"
                      phx-click="toggle_graph"
                      title={if @graph_expanded, do: "Collapse", else: "Expand"}
                    >
                      <.icon name={if @graph_expanded, do: "hero-arrows-pointing-in", else: "hero-arrows-pointing-out"} class="size-3" />
                    </button>
                  </div>
                </div>
                <%= if @graph_view == :graph do %>
                  <div
                    id="dep-graph"
                    class={[
                      "w-full rounded-xl relative overflow-hidden",
                      @graph_expanded && "h-[calc(100%-2rem)]" || "h-[420px]"
                    ]}
                    style="background: #151b28;"
                    phx-hook="DependencyGraph"
                    phx-update="ignore"
                  >
                  </div>
                <% else %>
                  <%!-- List view: hierarchical recursive tree --%>
                  <div class="overflow-y-auto max-h-[420px] pr-1 select-none">
                    <%= if @hierarchy do %>
                      <.tree_node
                        node={@hierarchy}
                        depth={0}
                        expanded={@list_expanded_nodes}
                        selected_id={@selected_agent && (@selected_agent[:id] || @selected_agent["id"])}
                      />
                    <% else %>
                      <div class="text-center text-xs text-base-content/40 py-12">
                        No agents registered. POST to <code class="font-mono">/api/register</code> to add agents.
                      </div>
                    <% end %>
                  </div>
                <% end %>
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
                        <span :if={agent[:story_id]} class="badge badge-xs badge-primary badge-outline font-mono">
                          {agent[:story_id]}
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
                :for={tab <- [:inspector, :ralph, :upm, :ports, :commands, :todos]}
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
                <%!-- Scope breadcrumb --%>
                <ApmV5Web.Components.ScopeBreadcrumb.breadcrumb scope={@chat_scope} />

                <%!-- Agent control panel --%>
                <ApmV5Web.Components.AgentControlPanel.control_bar
                  selected_agent={@selected_agent}
                  agent_status={if @selected_agent, do: @selected_agent.status, else: "unknown"}
                />

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

                <%!-- Chat panel below agent details --%>
                <div class="mt-3 border-t border-base-300 pt-2" style="height: 200px;">
                  <ApmV5Web.Components.InspectorChat.chat_panel
                    scope={@chat_scope}
                    messages={@chat_messages}
                    chat_input={@chat_input}
                    selected_agent={@selected_agent}
                  />
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

              <%!-- UPM tab --%>
              <div :if={@active_tab == :upm} class="space-y-2">
                <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                  UPM Sessions
                </h3>
                <div :if={!@upm_status.active} class="text-xs text-base-content/40 py-4 text-center">
                  No active UPM session. Start with <code>/upm build</code>.
                </div>
                <div :if={@upm_status.active} class="space-y-2">
                  <div class="p-2 rounded bg-base-300 text-xs space-y-1">
                    <div class="flex justify-between">
                      <span class="text-base-content/50">Session</span>
                      <span class="font-mono text-[10px]">{@upm_status.session.id}</span>
                    </div>
                    <div class="flex justify-between">
                      <span class="text-base-content/50">Status</span>
                      <span class={["badge badge-xs", upm_status_badge(@upm_status.session.status)]}>
                        {@upm_status.session.status}
                      </span>
                    </div>
                    <div class="flex justify-between">
                      <span class="text-base-content/50">Wave</span>
                      <span>{@upm_status.session.current_wave}/{@upm_status.session.total_waves}</span>
                    </div>
                    <div class="flex justify-between">
                      <span class="text-base-content/50">Stories</span>
                      <span>{upm_story_summary(@upm_status.session.stories)}</span>
                    </div>
                  </div>
                  <%!-- Full event timeline --%>
                  <div :if={@upm_status.events != []} class="space-y-0.5">
                    <div class="text-[10px] text-base-content/40 uppercase tracking-wider">Timeline</div>
                    <div :for={event <- Enum.reverse(@upm_status.events)} class="text-[10px] text-base-content/50 flex gap-2 py-0.5">
                      <span class="text-base-content/30 flex-shrink-0">{format_event_time(event.timestamp)}</span>
                      <span class={["font-medium", upm_event_color(event.event_type)]}>{event.event_type}</span>
                      <span :if={event.data["story_id"]} class="font-mono">{event.data["story_id"]}</span>
                    </div>
                  </div>
                </div>
              </div>

              <%!-- Ports tab --%>
              <div :if={@active_tab == :ports} class="space-y-3">
                <div class="flex items-center justify-between">
                  <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                    Port Manager
                  </h3>
                  <button phx-click="scan_ports" class="btn btn-xs btn-ghost text-primary">
                    <.icon name="hero-arrow-path" class="size-3" /> Scan
                  </button>
                </div>

                <%!-- Clash alerts --%>
                <div :if={@port_clashes != []} class="space-y-1">
                  <div class="text-[10px] uppercase tracking-wider text-error/70 font-semibold">Clashes</div>
                  <div :for={clash <- @port_clashes} class="p-2 rounded bg-error/10 border border-error/20 text-xs">
                    <div class="flex items-center gap-2 mb-1">
                      <span class="font-mono font-bold text-error">:{clash.port}</span>
                      <span class="text-base-content/50">{Enum.join(clash.projects, " + ")}</span>
                    </div>
                    <button phx-click="get_remediation" phx-value-port={clash.port}
                      class="text-[10px] text-primary hover:underline">
                      Suggest fix
                    </button>
                  </div>
                </div>

                <%!-- Remediation suggestion --%>
                <div :if={@port_remediation} class="p-2 rounded bg-info/10 border border-info/20 text-xs space-y-1">
                  <div class="font-semibold text-info">Remediation for :{@port_remediation.port}</div>
                  <div class="text-base-content/60">{@port_remediation.recommendation}</div>
                  <div :if={@port_remediation.alternatives != []} class="flex gap-1 mt-1">
                    <span class="text-[10px] text-base-content/40">Available:</span>
                    <span :for={alt <- @port_remediation.alternatives} class="badge badge-xs badge-ghost font-mono">{alt}</span>
                  </div>
                </div>

                <%!-- Project configs --%>
                <div :for={{name, config} <- Enum.sort_by(@project_configs, fn {n, _} -> n end)} class="space-y-1">
                  <div class="flex items-center justify-between">
                    <span class="text-xs font-semibold text-base-content/80">{name}</span>
                    <span class={["badge badge-xs", stack_badge(config.stack)]}>{config.stack}</span>
                  </div>
                  <div class="p-2 rounded bg-base-300 text-[10px] space-y-1">
                    <div class="text-base-content/40 font-mono truncate" title={config.root}>
                      {Path.basename(config.root)}
                    </div>
                    <%!-- Ports --%>
                    <div :for={port_info <- config.ports} class="space-y-0.5">
                      <div class="flex items-center gap-2">
                        <span class={["w-1.5 h-1.5 rounded-full", if(port_info[:active], do: "bg-success", else: "bg-base-content/20")]}></span>
                        <span class="font-mono font-bold">:{port_info.port}</span>
                        <span class={["badge badge-xs", ns_badge(port_info.namespace)]}>{port_info.namespace}</span>
                        <span :if={port_info[:server_type] && port_info[:server_type] != :unknown}
                          class={["badge badge-xs", server_type_badge(port_info[:server_type])]}>
                          {port_info[:server_type]}
                        </span>
                        <span class="text-base-content/30 ml-auto">{port_info.file}</span>
                      </div>
                      <div :if={port_info[:active]} class="pl-4 text-[9px] text-base-content/30 space-y-0.5">
                        <div :if={port_info[:cwd]} class="font-mono truncate" title={port_info[:cwd]}>
                          cwd: {port_info[:cwd]}
                        </div>
                        <div :if={port_info[:full_command]} class="font-mono truncate" title={port_info[:full_command]}>
                          cmd: {port_info[:full_command]}
                        </div>
                        <div :if={port_info[:pid]} class="font-mono">
                          pid: {port_info[:pid]}
                        </div>
                      </div>
                    </div>
                    <div :if={config.ports == []} class="text-base-content/30">No ports detected</div>
                    <%!-- Config files --%>
                    <details class="mt-1">
                      <summary class="text-base-content/30 cursor-pointer hover:text-base-content/50">
                        {length(config.config_files)} config files
                      </summary>
                      <div class="mt-1 space-y-0.5 pl-2">
                        <div :for={f <- config.config_files} class="text-base-content/40 font-mono">{f}</div>
                      </div>
                    </details>
                  </div>
                </div>

                <div :if={@project_configs == %{}} class="text-xs text-base-content/40 py-4 text-center">
                  No projects detected. Check ~/Developer/ccem/apm/sessions/
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

      <%!-- Getting Started Showcase --%>
      <.showcase show={@show_showcase} />
    </div>
    """
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

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

  # Scope navigation
  def handle_event("scope:set", %{"scope" => scope}, socket) do
    messages = ChatStore.list_messages(scope, 50)
    {:noreply, socket |> assign(:chat_scope, scope) |> assign(:chat_messages, messages)}
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

  # Wizard events (legacy)
  def handle_event("wizard:dismiss", _params, socket), do: {:noreply, socket}
  def handle_event("wizard:next", _params, socket), do: {:noreply, push_event(socket, "wizard:next", %{})}
  def handle_event("wizard:prev", _params, socket), do: {:noreply, push_event(socket, "wizard:prev", %{})}
  def handle_event("wizard:goto", %{"slide" => slide}, socket), do: {:noreply, push_event(socket, "wizard:goto", %{slide: slide})}

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
        messages = ChatStore.list_messages(scope, 50)

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
    PortManager.scan_active_ports()
    project_configs = PortManager.get_project_configs()
    port_clashes = PortManager.detect_clashes()
    {:noreply,
     socket
     |> assign(:project_configs, project_configs)
     |> assign(:port_clashes, port_clashes)}
  end

  def handle_event("get_remediation", %{"port" => port_str}, socket) do
    {port, _} = Integer.parse(port_str)
    remediation = PortManager.suggest_remediation(port)
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
    refresh_agents(socket)
  end

  def handle_info({:agent_updated, _agent}, socket) do
    refresh_agents(socket)
  end

  def handle_info({:agent_discovered, _agent_id, _project}, socket) do
    refresh_agents(socket)
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
    project_configs = PortManager.get_project_configs()
    port_clashes = PortManager.detect_clashes()
    {:noreply, socket |> assign(:project_configs, project_configs) |> assign(:port_clashes, port_clashes)}
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
  attr :badge, :any, default: nil

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
      <span :if={@badge && @badge > 0} class="badge badge-xs badge-primary ml-auto">{@badge}</span>
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

    # Push flat agents_updated (backward compat for legacy graph)
    socket = push_event(socket, "agents_updated", %{agents: graph_agents, edges: edges})

    # Push hierarchy_data via GraphBuilder for collapsible tree
    hierarchy = GraphBuilder.build_hierarchy(graph_agents, scope: :single_project)
    socket = assign(socket, :hierarchy, hierarchy)
    push_event(socket, "hierarchy_data", %{tree: hierarchy})
  end

  defp calculate_uptime do
    start_time = Application.get_env(:apm_v5, :server_start_time, System.system_time(:second))
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

  defp stack_badge(:elixir), do: "badge-accent"
  defp stack_badge(:nextjs), do: "badge-info"
  defp stack_badge(:node), do: "badge-success"
  defp stack_badge(:python), do: "badge-warning"
  defp stack_badge(_), do: "badge-ghost"

  defp ns_badge(:web), do: "badge-info"
  defp ns_badge(:api), do: "badge-accent"
  defp ns_badge(:service), do: "badge-warning"
  defp ns_badge(:tool), do: "badge-success"
  defp ns_badge(_), do: "badge-ghost"

  defp server_type_badge(:phoenix), do: "badge-accent"
  defp server_type_badge(:elixir), do: "badge-accent"
  defp server_type_badge(:nextjs), do: "badge-info"
  defp server_type_badge(:vite), do: "badge-primary"
  defp server_type_badge(:node), do: "badge-success"
  defp server_type_badge(:python_web), do: "badge-warning"
  defp server_type_badge(:postgres), do: "badge-secondary"
  defp server_type_badge(:redis), do: "badge-error"
  defp server_type_badge(_), do: "badge-ghost"

  defp tab_label(:inspector), do: "Inspector"
  defp tab_label(:ralph), do: "Ralph"
  defp tab_label(:upm), do: "UPM"
  defp tab_label(:ports), do: "Ports"
  defp tab_label(:commands), do: "Commands"
  defp tab_label(:todos), do: "TODOs"

  defp skill_count do
    try do
      map_size(ApmV5.SkillTracker.get_skill_catalog())
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
      catalog = ApmV5.SkillTracker.get_skill_catalog()
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

  # --- UPM Helpers ---

  defp upm_status_badge("registered"), do: "badge-ghost"
  defp upm_status_badge("running"), do: "badge-info"
  defp upm_status_badge("verifying"), do: "badge-warning"
  defp upm_status_badge("verified"), do: "badge-success"
  defp upm_status_badge("shipped"), do: "badge-accent"
  defp upm_status_badge(_), do: "badge-ghost"

  defp upm_story_dot("pending"), do: "bg-base-content/30"
  defp upm_story_dot("in_progress"), do: "bg-info"
  defp upm_story_dot("passed"), do: "bg-success"
  defp upm_story_dot("failed"), do: "bg-error"
  defp upm_story_dot(_), do: "bg-base-content/30"

  defp upm_story_summary(stories) when is_list(stories) do
    passed = Enum.count(stories, &(&1.status == "passed"))
    total = length(stories)
    "#{passed}/#{total} passed"
  end
  defp upm_story_summary(_), do: ""

  defp upm_event_color("wave_start"), do: "text-info"
  defp upm_event_color("wave_complete"), do: "text-info"
  defp upm_event_color("story_pass"), do: "text-success"
  defp upm_event_color("story_fail"), do: "text-error"
  defp upm_event_color("verify_start"), do: "text-warning"
  defp upm_event_color("verify_complete"), do: "text-success"
  defp upm_event_color("ship"), do: "text-accent"
  defp upm_event_color(_), do: "text-base-content/50"

  defp format_event_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end
  defp format_event_time(_), do: ""

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

  defp status_dot_class("active"), do: "bg-success"
  defp status_dot_class("running"), do: "bg-success"
  defp status_dot_class("error"), do: "bg-error"
  defp status_dot_class("warning"), do: "bg-warning"
  defp status_dot_class("completed"), do: "bg-purple-400"
  defp status_dot_class(_), do: "bg-base-content/30"
end
