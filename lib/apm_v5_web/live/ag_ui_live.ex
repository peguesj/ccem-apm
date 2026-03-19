defmodule ApmV5Web.AgUiLive do
  @moduledoc """
  AG-UI Protocol LiveView — real-time SSE event feed, event type filtering,
  agent state viewer, and router stats display.
  """

  use ApmV5Web, :live_view


  alias ApmV5.AgUi.EventRouter
  alias ApmV5.AgUi.StateManager
  alias ApmV5.AgentRegistry
  alias ApmV5.EventStream
  alias AgUi.Core.Events.EventType

  @event_types EventType.all()

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "ag_ui:events")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:agents")
    end

    router_stats = safe_stats()
    agents = AgentRegistry.list_agents()
    recent_events = EventStream.get_events(nil, 50)

    socket =
      socket
      |> assign(:page_title, "AG-UI Protocol")
      |> assign(:events, recent_events)
      |> assign(:router_stats, router_stats)
      |> assign(:agents, agents)
      |> assign(:selected_agent, nil)
      |> assign(:agent_state, nil)
      |> assign(:enabled_types, MapSet.new(@event_types))
      |> assign(:event_types, @event_types)
      |> assign(:paused, false)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <.sidebar_nav current_path="/ag-ui" />

      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Header --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold">AG-UI Protocol</h2>
            <div class="badge badge-sm badge-ghost">{length(@events)} events</div>
            <div class="badge badge-sm badge-ghost">{@router_stats.routed_count} routed</div>
          </div>
          <div class="flex items-center gap-2">
            <button phx-click="toggle_pause" class={["btn btn-xs", @paused && "btn-warning" || "btn-ghost"]}>
              <.icon name={if @paused, do: "hero-play", else: "hero-pause"} class="size-3" />
              {if @paused, do: "Resume", else: "Pause"}
            </button>
            <button phx-click="clear_events" class="btn btn-ghost btn-xs">
              <.icon name="hero-trash" class="size-3" /> Clear
            </button>
            <button phx-click="refresh" class="btn btn-ghost btn-xs">
              <.icon name="hero-arrow-path" class="size-3" /> Refresh
            </button>
          </div>
        </header>

        <div class="flex-1 flex overflow-hidden">
          <%!-- Event feed --%>
          <div class="flex-1 flex flex-col overflow-hidden">
            <%!-- Type filters --%>
            <div class="flex flex-wrap gap-1 p-2 border-b border-base-300 bg-base-200">
              <button
                :for={type <- @event_types}
                phx-click="toggle_type"
                phx-value-type={type}
                class={[
                  "badge badge-sm cursor-pointer transition-colors",
                  MapSet.member?(@enabled_types, type) && event_badge_class(type),
                  !MapSet.member?(@enabled_types, type) && "badge-ghost opacity-30"
                ]}
              >
                {type}
              </button>
            </div>

            <%!-- Event list --%>
            <div class="flex-1 overflow-y-auto p-2 space-y-1 font-mono text-xs" id="event-feed">
              <div :if={filtered_events(@events, @enabled_types) == []} class="text-center text-base-content/30 py-16">
                No AG-UI events yet. Events appear when agents emit via POST /api/v2/ag-ui/emit
              </div>
              <div
                :for={event <- filtered_events(@events, @enabled_types)}
                class="flex items-start gap-2 p-2 rounded bg-base-200 hover:bg-base-200/80"
              >
                <span class={["badge badge-xs flex-shrink-0 mt-0.5", event_badge_class(event.type)]}>
                  {event.type}
                </span>
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2">
                    <span :if={event.data[:agent_id]} class="text-primary/70">{event.data[:agent_id]}</span>
                    <span class="text-base-content/30">{format_ts(event.timestamp)}</span>
                  </div>
                  <div class="text-base-content/60 truncate mt-0.5">
                    {summarize_event(event)}
                  </div>
                </div>
              </div>
            </div>
          </div>

          <%!-- Right panel: Stats + Agent State --%>
          <div class="w-72 border-l border-base-300 bg-base-200 flex flex-col flex-shrink-0 overflow-y-auto">
            <%!-- Router Stats --%>
            <div class="p-4 border-b border-base-300">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3">Router Stats</h3>
              <div class="space-y-2">
                <div class="flex justify-between text-xs">
                  <span class="text-base-content/50">Total Routed</span>
                  <span class="font-mono">{@router_stats.routed_count}</span>
                </div>
                <div :for={{type, count} <- Enum.sort_by(@router_stats.by_type, fn {_, c} -> c end, :desc) |> Enum.take(10)} class="flex justify-between text-xs">
                  <span class={["badge badge-xs", event_badge_class(type)]}>{type}</span>
                  <span class="font-mono text-base-content/60">{count}</span>
                </div>
                <div :if={@router_stats.last_routed_at} class="text-[10px] text-base-content/30 mt-2">
                  Last: {format_ts(@router_stats.last_routed_at)}
                </div>
              </div>
            </div>

            <%!-- Agent State Viewer --%>
            <div class="p-4 border-b border-base-300">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3">Agent State</h3>
              <div class="space-y-1">
                <button
                  :for={agent <- @agents |> Enum.take(20)}
                  phx-click="select_agent"
                  phx-value-id={agent.id}
                  class={[
                    "w-full text-left px-2 py-1 rounded text-xs flex items-center gap-2 transition-colors",
                    @selected_agent == agent.id && "bg-primary/10 text-primary",
                    @selected_agent != agent.id && "text-base-content/60 hover:bg-base-300"
                  ]}
                >
                  <span class={["w-1.5 h-1.5 rounded-full", status_dot(agent.status)]}></span>
                  <span class="truncate">{agent.name || agent.id}</span>
                </button>
                <div :if={@agents == []} class="text-xs text-base-content/30 py-4 text-center">
                  No agents registered
                </div>
              </div>
            </div>

            <%!-- Selected Agent State --%>
            <div :if={@agent_state} class="p-4">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-2">
                State: {@selected_agent}
              </h3>
              <pre class="text-[10px] text-base-content/60 bg-base-300 rounded p-2 overflow-x-auto max-h-64">{Jason.encode!(@agent_state, pretty: true)}</pre>
            </div>
            <div :if={@selected_agent && !@agent_state} class="p-4 text-xs text-base-content/30 text-center">
              No state tracked for this agent
            </div>
          </div>
        </div>
      </div>
    </div>
    <.wizard page="ag-ui" dom_id="ccem-wizard-ag-ui-agui" />
    """
  end

  # --- Events ---

  @impl true
  def handle_event("toggle_type", %{"type" => type}, socket) do
    enabled = socket.assigns.enabled_types
    new_enabled =
      if MapSet.member?(enabled, type),
        do: MapSet.delete(enabled, type),
        else: MapSet.put(enabled, type)
    {:noreply, assign(socket, :enabled_types, new_enabled)}
  end

  def handle_event("toggle_pause", _params, socket) do
    {:noreply, assign(socket, :paused, !socket.assigns.paused)}
  end

  def handle_event("clear_events", _params, socket) do
    {:noreply, assign(socket, :events, [])}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:events, EventStream.get_events(nil, 50))
     |> assign(:router_stats, safe_stats())
     |> assign(:agents, AgentRegistry.list_agents())}
  end

  def handle_event("select_agent", %{"id" => id}, socket) do
    state = StateManager.get_state(id)
    {:noreply,
     socket
     |> assign(:selected_agent, id)
     |> assign(:agent_state, state)}
  end

  # --- PubSub ---

  @impl true
  def handle_info({:ag_ui_event, event}, socket) do
    if socket.assigns.paused do
      {:noreply, socket}
    else
      events = [event | socket.assigns.events] |> Enum.take(200)
      {:noreply,
       socket
       |> assign(:events, events)
       |> assign(:router_stats, safe_stats())}
    end
  end

  def handle_info({:agent_registered, _}, socket) do
    {:noreply, assign(socket, :agents, AgentRegistry.list_agents())}
  end

  def handle_info({:agent_updated, _}, socket) do
    {:noreply, assign(socket, :agents, AgentRegistry.list_agents())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp safe_stats do
    try do
      EventRouter.stats()
    catch
      :exit, _ -> %{routed_count: 0, by_type: %{}, last_routed_at: nil}
    end
  end

  defp filtered_events(events, enabled_types) do
    Enum.filter(events, fn e -> MapSet.member?(enabled_types, e.type) end)
  end

  defp format_ts(nil), do: ""
  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> ts
    end
  end
  defp format_ts(_), do: ""

  defp summarize_event(%{type: type, data: data}) when type in ["RUN_STARTED", "RUN_FINISHED", "RUN_ERROR"] do
    agent = data[:agent_id] || data[:run_id] || ""
    msg = data[:message] || data[:result] || ""
    "#{String.downcase(String.replace(type, "_", " "))} #{agent} #{msg}" |> String.trim()
  end

  defp summarize_event(%{type: type, data: data}) when type in ["STEP_STARTED", "STEP_FINISHED"] do
    step = data[:step_name] || ""
    wave = if data[:wave], do: " wave=#{data[:wave]}", else: ""
    "#{step}#{wave}"
  end

  defp summarize_event(%{type: "TOOL_CALL_START", data: data}) do
    tool = data[:tool_call_name] || data[:tool_name] || "unknown"
    agent = data[:agent_id] || ""
    "[#{agent}] #{tool}"
  end

  defp summarize_event(%{type: "TOOL_CALL_END", data: data}) do
    tool = data[:tool_call_name] || data[:tool_name] || ""
    dur = if data[:duration_ms], do: " (#{data[:duration_ms]}ms)", else: ""
    "#{tool}#{dur}"
  end

  defp summarize_event(%{type: "TOOL_CALL_ARGS", data: data}) do
    delta = data[:delta] || ""
    String.slice(delta, 0, 100)
  end

  defp summarize_event(%{type: "TOOL_CALL_RESULT", data: data}) do
    content = data[:content] || ""
    String.slice(content, 0, 100)
  end

  defp summarize_event(%{type: "TEXT_MESSAGE_CONTENT", data: data}) do
    delta = data[:delta] || ""
    String.slice(delta, 0, 120)
  end

  defp summarize_event(%{type: "TEXT_MESSAGE_START", data: data}) do
    role = data[:role] || "assistant"
    id = data[:message_id] || ""
    "role=#{role} id=#{id}"
  end

  defp summarize_event(%{type: "STATE_DELTA", data: data}) do
    ops = data[:delta] || []
    count = if is_list(ops), do: length(ops), else: 0
    source = data[:source] || ""
    "#{count} patch ops#{if source != "", do: " from #{source}", else: ""}"
  end

  defp summarize_event(%{type: "STATE_SNAPSHOT", data: data}) do
    agent = data[:agent_id] || ""
    keys = if is_map(data[:snapshot]), do: " #{map_size(data[:snapshot])} keys", else: ""
    "#{agent}#{keys}"
  end

  defp summarize_event(%{type: "MESSAGES_SNAPSHOT", data: data}) do
    count = if is_list(data[:messages]), do: length(data[:messages]), else: 0
    "#{count} messages"
  end

  defp summarize_event(%{type: "ACTIVITY_SNAPSHOT", data: data}) do
    type = data[:activity_type] || ""
    id = data[:message_id] || ""
    "#{type} #{id}" |> String.trim()
  end

  defp summarize_event(%{type: "ACTIVITY_DELTA", data: data}) do
    patches = if is_list(data[:patch]), do: length(data[:patch]), else: 0
    "#{data[:activity_type] || ""} #{patches} patches" |> String.trim()
  end

  defp summarize_event(%{type: "THINKING_START", data: data}) do
    data[:title] || "thinking..."
  end

  defp summarize_event(%{type: "THINKING_END", data: _}), do: "thinking complete"

  defp summarize_event(%{type: "CUSTOM", data: data}) do
    name = data[:name] || "custom"
    val = data[:value]
    msg = if is_map(val), do: val[:message] || val[:title] || "", else: inspect(val, limit: 40)
    "#{name}: #{msg}" |> String.trim_trailing(": ")
  end

  defp summarize_event(%{type: type, data: data}) when binary_part(type, 0, 9) == "REASONING" do
    id = data[:message_id] || ""
    delta = data[:delta] || ""
    content = if delta != "", do: " — #{String.slice(delta, 0, 60)}", else: ""
    "#{id}#{content}" |> String.trim()
  end

  defp summarize_event(%{data: data}) do
    data[:message] || data[:title] || inspect(data, limit: 60)
  end

  # Badge classes covering all 33 EventType values
  defp event_badge_class("RUN_STARTED"), do: "badge-success badge-outline"
  defp event_badge_class("RUN_FINISHED"), do: "badge-info badge-outline"
  defp event_badge_class("RUN_ERROR"), do: "badge-error badge-outline"
  defp event_badge_class("STEP_STARTED"), do: "badge-success"
  defp event_badge_class("STEP_FINISHED"), do: "badge-info"
  defp event_badge_class("TOOL_CALL_START"), do: "badge-warning badge-outline"
  defp event_badge_class("TOOL_CALL_ARGS"), do: "badge-warning"
  defp event_badge_class("TOOL_CALL_END"), do: "badge-warning"
  defp event_badge_class("TOOL_CALL_CHUNK"), do: "badge-warning opacity-70"
  defp event_badge_class("TOOL_CALL_RESULT"), do: "badge-warning badge-solid"
  defp event_badge_class("TEXT_MESSAGE_START"), do: "badge-primary badge-outline"
  defp event_badge_class("TEXT_MESSAGE_CONTENT"), do: "badge-primary"
  defp event_badge_class("TEXT_MESSAGE_END"), do: "badge-primary badge-outline opacity-70"
  defp event_badge_class("TEXT_MESSAGE_CHUNK"), do: "badge-primary opacity-70"
  defp event_badge_class("THINKING_TEXT_MESSAGE_START"), do: "badge-secondary badge-outline"
  defp event_badge_class("THINKING_TEXT_MESSAGE_CONTENT"), do: "badge-secondary"
  defp event_badge_class("THINKING_TEXT_MESSAGE_END"), do: "badge-secondary badge-outline opacity-70"
  defp event_badge_class("THINKING_START"), do: "badge-secondary badge-outline"
  defp event_badge_class("THINKING_END"), do: "badge-secondary opacity-70"
  defp event_badge_class("STATE_SNAPSHOT"), do: "badge-accent badge-outline"
  defp event_badge_class("STATE_DELTA"), do: "badge-accent"
  defp event_badge_class("MESSAGES_SNAPSHOT"), do: "badge-primary badge-solid"
  defp event_badge_class("ACTIVITY_SNAPSHOT"), do: "badge-neutral badge-outline"
  defp event_badge_class("ACTIVITY_DELTA"), do: "badge-neutral"
  defp event_badge_class("REASONING_START"), do: "badge-secondary badge-outline"
  defp event_badge_class("REASONING_MESSAGE_START"), do: "badge-secondary"
  defp event_badge_class("REASONING_MESSAGE_CONTENT"), do: "badge-secondary"
  defp event_badge_class("REASONING_MESSAGE_END"), do: "badge-secondary opacity-70"
  defp event_badge_class("REASONING_MESSAGE_CHUNK"), do: "badge-secondary opacity-70"
  defp event_badge_class("REASONING_END"), do: "badge-secondary badge-outline opacity-70"
  defp event_badge_class("REASONING_ENCRYPTED_VALUE"), do: "badge-error badge-outline"
  defp event_badge_class("RAW"), do: "badge-ghost badge-outline"
  defp event_badge_class("CUSTOM"), do: "badge-secondary badge-outline"
  defp event_badge_class(_), do: "badge-ghost"

  defp status_dot("active"), do: "bg-success"
  defp status_dot("error"), do: "bg-error"
  defp status_dot("idle"), do: "bg-base-content/30"
  defp status_dot(_), do: "bg-base-content/20"
end
