defmodule ApmV5Web.AgUiPluginLive do
  @moduledoc """
  LiveView for the AG-UI plugin page at /plugins/ag_ui.

  Three tabs:
    - Events  — Live AG-UI event stream from EventBus replay buffer. Subscribes
                to "ag_ui:events" PubSub and "apm:agents". Shows event type
                badge (colour-coded), agent_id, timestamp, payload preview.
                Capped at 100 events.
    - Agents  — AG-UI context per agent from AgentContextStore. Shows agent_id,
                activity label, current event type, current tool, recent event
                counts, last updated timestamp.
    - Config  — AG-UI integration status: ag_ui_ex availability, full event-type
                list from EventType.all/0, EventBus statistics, hook health.
  """

  use ApmV5Web, :live_view

  alias ApmV5.AgUi.AgentContextStore
  alias ApmV5.AgUi.EventBus
  alias ApmV5.EventStream

  @pubsub_events "ag_ui:events"
  @pubsub_agents "apm:agents"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_events)
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_agents)
    end

    socket =
      socket
      |> assign(:page_title, "AG-UI Plugin")
      |> assign(:active_tab, "events")
      |> assign(:current_path, "/plugins/ag_ui")
      |> assign(:active_skill_count, skill_count())
      |> assign(:paused, false)
      |> load_events()
      |> load_agents()
      |> load_config()

    {:ok, socket |> assign(:sidebar_collapsed, false)
     |> assign(:inspector_open, false)
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  @impl true
  def handle_params(%{"tab" => tab}, _uri, socket)
      when tab in ["events", "agents", "config"] do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # --- Events ---

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
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
     |> load_events()
     |> load_agents()
     |> load_config()}
  end

  # --- PubSub ---

  @impl true
  def handle_info({:ag_ui_event, event}, socket) do
    if socket.assigns.paused do
      {:noreply, socket}
    else
      events = [event | socket.assigns.events] |> Enum.take(100)
      {:noreply, assign(socket, :events, events)}
    end
  end

  def handle_info({:agent_registered, _}, socket) do
    {:noreply, load_agents(socket)}
  end

  def handle_info({:agent_updated, _}, socket) do
    {:noreply, load_agents(socket)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav current_path={@current_path} skill_count={@active_skill_count} />
      </:sidebar>
      <:main>

      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Header --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0 relative z-10">
          <div class="flex items-center gap-3">
            <span class="inline-flex items-center justify-center w-6 h-6 rounded bg-secondary/10">
              <.icon name="hero-bolt" class="size-4 text-secondary" />
            </span>
            <h2 class="text-sm font-semibold text-base-content">AG-UI Plugin</h2>
            <div class="badge badge-sm badge-ghost">{length(@events)} events</div>
            <div :if={@config.event_bus_alive} class="badge badge-sm badge-success badge-outline">EventBus live</div>
            <div :if={not @config.event_bus_alive} class="badge badge-sm badge-error badge-outline">EventBus down</div>
          </div>
          <div class="flex items-center gap-2">
            <button
              :if={@active_tab == "events"}
              class={["btn btn-xs", @paused && "btn-warning" || "btn-ghost"]}
              phx-click="toggle_pause"
            >
              <.icon name={if @paused, do: "hero-play", else: "hero-pause"} class="size-3" />
              {if @paused, do: "Resume", else: "Pause"}
            </button>
            <button
              :if={@active_tab == "events"}
              class="btn btn-ghost btn-xs"
              phx-click="clear_events"
            >
              <.icon name="hero-trash" class="size-3" /> Clear
            </button>
            <button class="btn btn-ghost btn-xs" phx-click="refresh">
              <.icon name="hero-arrow-path" class="size-3" /> Refresh
            </button>
          </div>
        </header>

        <%!-- Tab bar --%>
        <div class="bg-base-200 border-b border-base-300 px-4 flex gap-1 flex-shrink-0">
          <.tab_btn tab="events" active_tab={@active_tab} label="Events" />
          <.tab_btn tab="agents" active_tab={@active_tab} label="Agents" />
          <.tab_btn tab="config" active_tab={@active_tab} label="Config" />
        </div>

        <%!-- Content --%>
        <div class="flex-1 overflow-y-auto p-6">

          <%!-- Events Tab --%>
          <div :if={@active_tab == "events"}>
            <div :if={@events == []} class="text-center text-base-content/30 py-16 text-sm">
              No AG-UI events yet. Events appear when agents emit via POST /api/v2/ag-ui/emit
            </div>

            <div class="space-y-1 font-mono text-xs" id="ag-ui-plugin-event-feed">
              <div
                :for={event <- @events}
                class="flex items-start gap-2 p-2 rounded bg-base-200 hover:bg-base-200/80"
              >
                <span class={["badge badge-xs flex-shrink-0 mt-0.5", event_badge_class(event_type(event))]}>
                  {event_type(event)}
                </span>
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2">
                    <span :if={event_agent_id(event)} class="text-primary/70 truncate max-w-[12rem]">
                      {event_agent_id(event)}
                    </span>
                    <span class="text-base-content/30 flex-shrink-0">{format_ts(event_ts(event))}</span>
                  </div>
                  <div class="text-base-content/60 truncate mt-0.5">
                    {summarize_event(event)}
                  </div>
                </div>
              </div>
            </div>
          </div>

          <%!-- Agents Tab --%>
          <div :if={@active_tab == "agents"}>
            <div :if={@agents == []} class="text-center text-base-content/30 py-16 text-sm">
              No AG-UI agent context tracked yet.
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
              <div
                :for={{agent_id, ctx} <- @agents}
                class="bg-base-200 rounded-lg p-4 flex flex-col gap-2"
              >
                <div class="flex items-center justify-between gap-2">
                  <span class="font-mono text-xs text-base-content/70 truncate flex-1">{agent_id}</span>
                  <span :if={ctx.current_event_type} class={["badge badge-xs flex-shrink-0", event_badge_class(ctx.current_event_type)]}>
                    {ctx.current_event_type}
                  </span>
                </div>

                <div class="text-sm text-base-content font-medium">
                  {Map.get(ctx, :activity_label, "Idle")}
                </div>

                <div :if={ctx.current_tool} class="text-xs text-base-content/50 font-mono">
                  tool: {ctx.current_tool}
                </div>

                <div :if={ctx.recent_events != []} class="flex flex-wrap gap-1 mt-1">
                  <span
                    :for={ev <- Enum.take(ctx.recent_events || [], 5)}
                    class={["badge badge-xs", event_badge_class(ev_type(ev))]}
                  >
                    {ev_type(ev)}
                  </span>
                </div>

                <div class="text-[10px] text-base-content/30 mt-1">
                  <span :if={ctx.updated_at}>Updated: {format_ts(ctx.updated_at)}</span>
                  <span :if={ctx.started_at} class="ml-2">Started: {format_ts(ctx.started_at)}</span>
                </div>
              </div>
            </div>
          </div>

          <%!-- Config Tab --%>
          <div :if={@active_tab == "config"}>
            <%!-- Integration Status --%>
            <div class="mb-6">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3">Integration Status</h3>
              <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div class="bg-base-200 rounded-lg p-4">
                  <div class="text-xs text-base-content/50 mb-1">ag_ui_ex package</div>
                  <div class={["badge badge-sm", @config.ag_ui_available && "badge-success" || "badge-error"]}>
                    {if @config.ag_ui_available, do: "loaded", else: "unavailable"}
                  </div>
                </div>
                <div class="bg-base-200 rounded-lg p-4">
                  <div class="text-xs text-base-content/50 mb-1">EventBus</div>
                  <div class={["badge badge-sm", @config.event_bus_alive && "badge-success" || "badge-error"]}>
                    {if @config.event_bus_alive, do: "running", else: "down"}
                  </div>
                  <div :if={@config.event_bus_stats} class="text-[10px] text-base-content/40 mt-1">
                    {Map.get(@config.event_bus_stats, :published_count, 0)} published ·
                    {Map.get(@config.event_bus_stats, :subscribers_count, 0)} subscribers
                  </div>
                </div>
                <div class="bg-base-200 rounded-lg p-4">
                  <div class="text-xs text-base-content/50 mb-1">AgentContextStore</div>
                  <div class={["badge badge-sm", @config.context_store_alive && "badge-success" || "badge-error"]}>
                    {if @config.context_store_alive, do: "running", else: "down"}
                  </div>
                  <div class="text-[10px] text-base-content/40 mt-1">
                    {map_size(@agents)} agents tracked
                  </div>
                </div>
              </div>
            </div>

            <%!-- EventBus Topic Stats --%>
            <div :if={@config.event_bus_stats} class="mb-6">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3">EventBus Topic Stats</h3>
              <div class="bg-base-200 rounded-lg p-4">
                <div :if={map_size(Map.get(@config.event_bus_stats, :by_topic, %{})) == 0} class="text-sm text-base-content/30">
                  No topic activity yet.
                </div>
                <div class="space-y-1">
                  <div
                    :for={{topic, count} <- Enum.sort_by(Map.get(@config.event_bus_stats, :by_topic, %{}), fn {_, c} -> c end, :desc) |> Enum.take(15)}
                    class="flex justify-between text-xs"
                  >
                    <span class="text-base-content/60 font-mono">{topic}</span>
                    <span class="font-mono text-base-content/40">{count}</span>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Event Types --%>
            <div>
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3">
                Event Types ({length(@config.event_types)})
              </h3>
              <div class="flex flex-wrap gap-1">
                <span
                  :for={type <- @config.event_types}
                  class={["badge badge-sm", event_badge_class(type)]}
                >
                  {type}
                </span>
                <div :if={@config.event_types == []} class="text-sm text-base-content/30">
                  ag_ui_ex not available — event types unavailable
                </div>
              </div>
            </div>
          </div>

        </div>
      </div>
      </:main>
    </.page_layout>
    """
  end

  # --- Private helpers ---

  defp tab_btn(assigns) do
    active = assigns.active_tab == assigns.tab
    assigns = assign(assigns, :is_active, active)

    ~H"""
    <button
      class={[
        "px-3 py-2 text-xs font-medium border-b-2 transition-colors",
        @is_active && "border-secondary text-secondary",
        !@is_active && "border-transparent text-base-content/50 hover:text-base-content"
      ]}
      phx-click="switch_tab"
      phx-value-tab={@tab}
    >
      {@label}
    </button>
    """
  end

  @spec load_events(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_events(socket) do
    events =
      try do
        EventStream.get_events(nil, 100)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    assign(socket, :events, events)
  end

  @spec load_agents(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_agents(socket) do
    agents =
      try do
        AgentContextStore.list_contexts()
      rescue
        _ -> %{}
      catch
        :exit, _ -> %{}
      end

    assign(socket, :agents, agents)
  end

  @spec load_config(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_config(socket) do
    ag_ui_available =
      try do
        Code.ensure_loaded?(AgUi.Core.Events.EventType)
      rescue
        _ -> false
      end

    event_types =
      if ag_ui_available do
        try do
          AgUi.Core.Events.EventType.all()
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end
      else
        []
      end

    {event_bus_alive, event_bus_stats} =
      try do
        stats = EventBus.stats()
        {true, stats}
      rescue
        _ -> {false, nil}
      catch
        :exit, _ -> {false, nil}
      end

    context_store_alive = Process.whereis(ApmV5.AgUi.AgentContextStore) != nil

    config = %{
      ag_ui_available: ag_ui_available,
      event_types: event_types,
      event_bus_alive: event_bus_alive,
      event_bus_stats: event_bus_stats,
      context_store_alive: context_store_alive
    }

    assign(socket, :config, config)
  end

  # Normalise event struct vs map access
  defp event_type(%{type: t}), do: t
  defp event_type(%{"type" => t}), do: t
  defp event_type(_), do: "UNKNOWN"

  defp event_agent_id(%{data: d}) when is_map(d), do: d[:agent_id] || d["agent_id"]
  defp event_agent_id(%{"data" => d}) when is_map(d), do: d[:agent_id] || d["agent_id"]
  defp event_agent_id(_), do: nil

  defp event_ts(%{timestamp: ts}), do: ts
  defp event_ts(%{"timestamp" => ts}), do: ts
  defp event_ts(_), do: nil

  defp ev_type(%{type: t}), do: t
  defp ev_type(%{"type" => t}), do: t
  defp ev_type(_), do: "?"

  @spec summarize_event(map()) :: String.t()
  defp summarize_event(event) do
    data =
      case event do
        %{data: d} -> d
        %{"data" => d} -> d
        _ -> %{}
      end

    type = event_type(event)

    cond do
      type in ["RUN_STARTED", "RUN_FINISHED", "RUN_ERROR"] ->
        agent = data[:agent_id] || data["agent_id"] || data[:run_id] || data["run_id"] || ""
        msg = data[:message] || data["message"] || data[:result] || data["result"] || ""
        "#{String.downcase(String.replace(type, "_", " "))} #{agent} #{msg}" |> String.trim()

      type in ["STEP_STARTED", "STEP_FINISHED"] ->
        step = data[:step_name] || data["step_name"] || ""
        wave = if data[:wave] || data["wave"], do: " wave=#{data[:wave] || data["wave"]}", else: ""
        "#{step}#{wave}"

      type == "TOOL_CALL_START" ->
        tool = data[:tool_call_name] || data["tool_call_name"] || data[:tool_name] || data["tool_name"] || "unknown"
        agent = data[:agent_id] || data["agent_id"] || ""
        "[#{agent}] #{tool}"

      type == "TOOL_CALL_END" ->
        tool = data[:tool_call_name] || data["tool_call_name"] || ""
        dur = data[:duration_ms] || data["duration_ms"]
        if dur, do: "#{tool} (#{dur}ms)", else: "#{tool}"

      type == "TEXT_MESSAGE_CONTENT" ->
        delta = data[:delta] || data["delta"] || ""
        String.slice(delta, 0, 120)

      type == "TEXT_MESSAGE_START" ->
        role = data[:role] || data["role"] || "assistant"
        id = data[:message_id] || data["message_id"] || ""
        "role=#{role} id=#{id}"

      type == "STATE_DELTA" ->
        ops = data[:delta] || data["delta"] || []
        count = if is_list(ops), do: length(ops), else: 0
        source = data[:source] || data["source"] || ""
        "#{count} patch ops#{if source != "", do: " from #{source}", else: ""}"

      type == "STATE_SNAPSHOT" ->
        agent = data[:agent_id] || data["agent_id"] || ""
        snap = data[:snapshot] || data["snapshot"]
        keys = if is_map(snap), do: " #{map_size(snap)} keys", else: ""
        "#{agent}#{keys}"

      type == "CUSTOM" ->
        name = data[:name] || data["name"] || "custom"
        val = data[:value] || data["value"]
        msg = if is_map(val), do: val[:message] || val["message"] || val[:title] || val["title"] || "", else: inspect(val, limit: 40)
        "#{name}: #{msg}" |> String.trim_trailing(": ")

      true ->
        msg = data[:message] || data["message"] || data[:title] || data["title"]
        if msg, do: inspect(msg, limit: 60), else: ""
    end
  end

  @spec format_ts(term()) :: String.t()
  defp format_ts(nil), do: ""
  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> ts
    end
  end
  defp format_ts(_), do: ""

  # Badge classes — covers all 33 EventType values
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

  @spec skill_count() :: non_neg_integer()
  defp skill_count do
    try do
      map_size(ApmV5.SkillTracker.get_skill_catalog())
    catch
      :exit, _ -> 0
    end
  end
end
