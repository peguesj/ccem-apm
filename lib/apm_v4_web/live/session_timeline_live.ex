defmodule ApmV4Web.SessionTimelineLive do
  @moduledoc """
  LiveView for session timeline with D3 gantt-style visualization.
  Shows agent activity over time with interactive filtering by session and time range.
  """

  use ApmV4Web, :live_view

  import ApmV4Web.Accessibility

  alias ApmV4.AgentRegistry


  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:agents")
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:audit")
    end

    sessions = AgentRegistry.list_sessions()
    agents = AgentRegistry.list_agents()
    time_range = "1h"

    socket =
      socket
      |> assign(:page_title, "Session Timeline")
      |> assign(:sessions, sessions)
      |> assign(:agents, agents)
      |> assign(:selected_session, nil)
      |> assign(:time_range, time_range)
      |> assign(:active_nav, :timeline)
      |> push_timeline_data(agents, time_range)

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
          <p class="text-xs text-base-content/50 mt-1">Session Timeline</p>
        </div>
        <nav class="flex-1 p-2 space-y-1">
          <.nav_item icon="hero-squares-2x2" label="Dashboard" active={false} href="/" />
          <.nav_item icon="hero-globe-alt" label="All Projects" active={false} href="/apm-all" />
          <.nav_item icon="hero-arrow-path" label="Ralph" active={false} href="/ralph" />
          <.nav_item icon="hero-clock" label="Timeline" active={true} href="/timeline" />
        </nav>

        <%!-- Session list --%>
        <div class="flex-1 overflow-y-auto p-2 border-t border-base-300">
          <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-2 px-1">
            Sessions
          </h3>
          <button
            class={[
              "w-full text-left px-2 py-1.5 rounded text-xs transition-colors mb-1",
              is_nil(@selected_session) && "bg-primary/10 text-primary font-medium",
              !is_nil(@selected_session) && "text-base-content/60 hover:bg-base-300"
            ]}
            phx-click="select_session"
            phx-value-session_id=""
          >
            All Sessions
          </button>
          <button
            :for={session <- @sessions}
            class={[
              "w-full text-left px-2 py-1.5 rounded text-xs transition-colors mb-1 truncate",
              @selected_session == session.session_id && "bg-primary/10 text-primary font-medium",
              @selected_session != session.session_id && "text-base-content/60 hover:bg-base-300"
            ]}
            phx-click="select_session"
            phx-value-session_id={session.session_id}
          >
            <div class="truncate">{session.session_id}</div>
            <div class="text-[10px] text-base-content/30">{session.project}</div>
          </button>
          <p :if={@sessions == []} class="text-[10px] text-base-content/30 px-1">
            No sessions registered
          </p>
        </div>
      </aside>

      <%!-- Main content --%>
      <div id="main-content" class="flex-1 flex flex-col overflow-hidden">
        <%!-- Top bar --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Session Timeline</h2>
            <div class="badge badge-sm badge-ghost">
              {length(@agents)} agents
            </div>
          </div>
          <div class="flex items-center gap-2">
            <%!-- Time range selector --%>
            <div class="join">
              <button
                :for={range <- ["1h", "6h", "24h"]}
                class={[
                  "join-item btn btn-xs",
                  @time_range == range && "btn-primary",
                  @time_range != range && "btn-ghost"
                ]}
                phx-click="set_time_range"
                phx-value-range={range}
              >
                {range}
              </button>
            </div>
            <button class="btn btn-ghost btn-xs" phx-click="refresh">
              <.icon name="hero-arrow-path" class="size-3" />
              Refresh
            </button>
          </div>
        </header>

        <%!-- Timeline visualization --%>
        <div class="flex-1 p-4 overflow-hidden">
          <.live_region id="timeline-status" politeness="polite">
            <div class="text-xs text-base-content/40 mb-2">
              Showing {length(filtered_agents(@agents, @selected_session, @sessions))} agents
              {if @selected_session, do: "for session #{@selected_session}", else: "across all sessions"}
              — last {@time_range}
            </div>
          </.live_region>

          <div
            id="session-timeline"
            class="w-full h-[calc(100%-2rem)] bg-base-200 rounded border border-base-300"
            phx-hook="SessionTimeline"
            phx-update="ignore"
            role="img"
            aria-label="Session timeline gantt chart showing agent activity over time"
          >
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("select_session", %{"session_id" => ""}, socket) do
    agents = AgentRegistry.list_agents()

    socket =
      socket
      |> assign(:selected_session, nil)
      |> assign(:agents, agents)
      |> push_timeline_data(agents, socket.assigns.time_range)

    {:noreply, socket}
  end

  def handle_event("select_session", %{"session_id" => session_id}, socket) do
    agents = AgentRegistry.list_agents()

    socket =
      socket
      |> assign(:selected_session, session_id)
      |> assign(:agents, agents)
      |> push_timeline_data(agents, socket.assigns.time_range)

    {:noreply, socket}
  end

  def handle_event("set_time_range", %{"range" => range}, socket)
      when range in ["1h", "6h", "24h"] do
    agents = socket.assigns.agents

    socket =
      socket
      |> assign(:time_range, range)
      |> push_timeline_data(agents, range)

    {:noreply, socket}
  end

  def handle_event("refresh", _params, socket) do
    sessions = AgentRegistry.list_sessions()
    agents = AgentRegistry.list_agents()

    socket =
      socket
      |> assign(:sessions, sessions)
      |> assign(:agents, agents)
      |> push_timeline_data(agents, socket.assigns.time_range)

    {:noreply, socket}
  end

  # --- PubSub Handlers ---

  @impl true
  def handle_info({:agent_registered, _agent}, socket) do
    refresh_data(socket)
  end

  def handle_info({:agent_updated, _agent}, socket) do
    refresh_data(socket)
  end

  def handle_info({:audit_event, _event}, socket) do
    refresh_data(socket)
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # --- Private Helpers ---

  defp refresh_data(socket) do
    sessions = AgentRegistry.list_sessions()
    agents = AgentRegistry.list_agents()

    socket =
      socket
      |> assign(:sessions, sessions)
      |> assign(:agents, agents)
      |> push_timeline_data(agents, socket.assigns.time_range)

    {:noreply, socket}
  end

  defp push_timeline_data(socket, agents, time_range) do
    now = DateTime.utc_now()
    selected_session = socket.assigns[:selected_session]
    sessions = socket.assigns[:sessions] || []

    filtered = filtered_agents(agents, selected_session, sessions)

    cutoff = time_range_cutoff(now, time_range)

    timeline_entries =
      Enum.map(filtered, fn agent ->
        start_time = agent.registered_at || DateTime.to_iso8601(now)

        end_time =
          if agent.status in ["active", "idle", "running"] do
            DateTime.to_iso8601(now)
          else
            agent.last_seen || DateTime.to_iso8601(now)
          end

        %{
          id: agent.id,
          name: agent.name || agent.id,
          status: agent.status,
          start_time: start_time,
          end_time: end_time,
          tool_calls: Map.get(agent.metadata || %{}, "tool_calls", 0)
        }
      end)

    push_event(socket, "timeline_data", %{
      entries: timeline_entries,
      time_range: time_range,
      cutoff: DateTime.to_iso8601(cutoff),
      now: DateTime.to_iso8601(now)
    })
  end

  defp filtered_agents(agents, nil, _sessions), do: agents

  defp filtered_agents(agents, session_id, sessions) do
    session = Enum.find(sessions, fn s -> s.session_id == session_id end)

    if session do
      project = session.project
      Enum.filter(agents, fn a -> a[:project_name] == project || is_nil(a[:project_name]) end)
    else
      agents
    end
  end

  defp time_range_cutoff(now, "1h"), do: DateTime.add(now, -3600, :second)
  defp time_range_cutoff(now, "6h"), do: DateTime.add(now, -21600, :second)
  defp time_range_cutoff(now, "24h"), do: DateTime.add(now, -86400, :second)
  defp time_range_cutoff(now, _), do: DateTime.add(now, -3600, :second)

  # --- Components ---

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
end
