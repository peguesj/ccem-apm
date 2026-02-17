defmodule ApmV4Web.DashboardLive do
  @moduledoc """
  LiveView dashboard for CCEM APM v4.

  Ported from the Python APM v3 embedded HTML dashboard to Phoenix LiveView
  with daisyUI components. Displays agent fleet status, stats cards, notification
  toasts, and sidebar navigation.
  """

  use ApmV4Web, :live_view

  alias ApmV4.AgentRegistry

  @impl true
  def mount(_params, _session, socket) do
    agents = AgentRegistry.list_agents()
    notifications = AgentRegistry.get_notifications()
    uptime = calculate_uptime()

    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> assign(:agents, agents)
      |> assign(:notifications, notifications)
      |> assign(:uptime, uptime)
      |> assign(:agent_count, length(agents))
      |> assign(:active_count, Enum.count(agents, &(&1.status == "active")))
      |> assign(:idle_count, Enum.count(agents, &(&1.status == "idle")))
      |> assign(:error_count, Enum.count(agents, &(&1.status == "error")))
      |> assign(:active_nav, :dashboard)
      |> assign(:active_tab, :inspector)
      |> assign(:selected_agent, nil)
      |> push_graph_data(agents)

    {:ok, socket}
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
          <.nav_item icon="hero-cpu-chip" label="Agents" active={@active_nav == :agents} href="/" />
          <.nav_item icon="hero-arrow-path" label="Ralph" active={@active_nav == :ralph} href="/ralph" />
          <.nav_item icon="hero-clock" label="Sessions" active={@active_nav == :sessions} href="/" />
          <.nav_item icon="hero-cog-6-tooth" label="Settings" active={@active_nav == :settings} href="/" />
        </nav>
        <div class="p-3 border-t border-base-300">
          <div class="text-xs text-base-content/40">
            <div>Phoenix {Application.spec(:phoenix, :vsn)}</div>
            <div>Uptime: {@uptime}</div>
          </div>
        </div>
      </aside>

      <%!-- Main content --%>
      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Top bar --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Dashboard</h2>
            <div class="badge badge-sm badge-ghost">
              {@agent_count} agents
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
                  </div>
                </div>
              </div>
            </div>
            <Layouts.theme_toggle />
          </div>
        </header>

        <%!-- Dashboard body --%>
        <div class="flex-1 flex overflow-hidden">
          <%!-- Left panel: stats + agents --%>
          <div class="flex-1 overflow-y-auto p-4 space-y-4">
            <%!-- Stats grid --%>
            <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3">
              <.stat_card label="Agents" value={@agent_count} color="text-primary" />
              <.stat_card label="Active" value={@active_count} color="text-success" />
              <.stat_card label="Idle" value={@idle_count} color="text-base-content/60" />
              <.stat_card label="Errors" value={@error_count} color="text-error" />
              <.stat_card label="Sessions" value={length(AgentRegistry.list_sessions())} color="text-info" />
              <.stat_card label="Notifications" value={length(@notifications)} color="text-warning" />
            </div>

            <%!-- D3 Dependency Graph --%>
            <div class="card bg-base-200 border border-base-300">
              <div class="card-body p-3">
                <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-2">
                  Dependency Graph
                </h3>
                <div
                  id="dep-graph"
                  class="w-full h-48 rounded bg-base-300 relative"
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
              <div class="grid grid-cols-[24px_1fr_80px_80px] gap-2 px-3 mb-1 text-[10px] uppercase tracking-wider text-base-content/30">
                <span></span>
                <span>Agent</span>
                <span class="text-right">Last Seen</span>
                <span class="text-center">Status</span>
              </div>
              <%!-- Agent rows --%>
              <div class="space-y-1">
                <div
                  :for={agent <- @agents}
                  class="card bg-base-200 border border-base-300 hover:border-primary/50 transition-colors cursor-pointer"
                >
                  <div class="grid grid-cols-[24px_1fr_80px_80px] gap-2 items-center px-3 py-2">
                    <div class={["badge badge-xs", tier_badge_class(agent.tier)]}>
                      {agent.tier}
                    </div>
                    <div>
                      <div class="text-sm font-medium truncate">{agent.name}</div>
                      <div class="text-[10px] text-base-content/30">{agent.id}</div>
                    </div>
                    <div class="text-right text-xs text-base-content/40">
                      {format_last_seen(agent.last_seen)}
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
                <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                  Ralph Methodology
                </h3>
                <p class="text-xs text-base-content/40">
                  Ralph flowchart will be rendered in a dedicated /ralph route.
                </p>
              </div>

              <%!-- Commands tab --%>
              <div :if={@active_tab == :commands} class="space-y-2">
                <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                  Slash Commands
                </h3>
                <p class="text-xs text-base-content/40">
                  Command registry will be populated via API.
                </p>
              </div>

              <%!-- TODOs tab --%>
              <div :if={@active_tab == :todos} class="space-y-2">
                <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                  Active Tasks
                </h3>
                <p class="text-xs text-base-content/40">
                  TODO tracking will be populated via API.
                </p>
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

  defp push_graph_data(socket, agents) do
    graph_agents =
      Enum.map(agents, fn agent ->
        %{
          id: agent.id,
          name: agent.name,
          tier: agent.tier,
          status: agent.status,
          deps: agent.deps || [],
          metadata: agent.metadata || %{}
        }
      end)

    # Build edges from agent deps
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
  defp status_badge_class(_), do: "badge-ghost"

  defp tier_badge_class(1), do: "badge-primary"
  defp tier_badge_class(2), do: "badge-secondary"
  defp tier_badge_class(3), do: "badge-warning"
  defp tier_badge_class(_), do: "badge-ghost"

  defp notif_badge_class("error"), do: "badge-error"
  defp notif_badge_class("warning"), do: "badge-warning"
  defp notif_badge_class("success"), do: "badge-success"
  defp notif_badge_class("info"), do: "badge-info"
  defp notif_badge_class(_), do: "badge-ghost"

  defp tab_label(:inspector), do: "Inspector"
  defp tab_label(:ralph), do: "Ralph"
  defp tab_label(:commands), do: "Commands"
  defp tab_label(:todos), do: "TODOs"
end
