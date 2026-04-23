defmodule ApmV5Web.SessionTimelineLive do
  @moduledoc """
  LiveView for session timeline with swim-lane visualization.

  Displays events grouped into six category swim lanes — lifecycle, auth,
  formation, task, tool, system — each rendered as a horizontal track with
  colour-coded event dots positioned by relative timestamp.  A right-side
  drill-down panel slides in when an event dot is selected.  Time-window
  and per-lane toggle controls are fully server-side; no custom JS required.
  """

  use ApmV5Web, :live_view

  import ApmV5Web.Accessibility
  import ApmV5Web.Components.GettingStartedWizard

  alias ApmV5.AgentRegistry
  alias ApmV5.AuditLog

  # ---- Constants -----------------------------------------------------------

  @categories ~w(lifecycle auth formation task tool system)

  # Keyword prefixes that map an audit event_type to a swim-lane category.
  # Order matters — first match wins.
  @category_patterns [
    {"lifecycle", ["agent_register", "agent_update", "ag_ui.run_started", "ag_ui.run_finished",
                   "ag_ui.run_error", "register", "deregister", "session"]},
    {"auth",      ["auth", "agentlock", "ag_ui.approval", "authorization", "token", "rate_limit"]},
    {"formation", ["formation", "fmt", "squadron", "swarm", "cluster", "orchestrat"]},
    {"task",      ["task", "bg_task", "background", "action"]},
    {"tool",      ["tool", "ag_ui.tool", "TOOL_CALL", "call_start", "call_end", "call_args"]},
    {"system",    []}   # catch-all
  ]

  # ---- Mount ---------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:agents")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:audit")
      ApmV5.AgUi.EventBus.subscribe("lifecycle:*")
      ApmV5.AgUi.EventBus.subscribe("tool:*")
      ApmV5.AgUi.EventBus.subscribe("state:*")
    end

    socket =
      socket
      |> assign(:page_title, "Session Timeline")
      |> assign(:active_nav, :timeline)
      |> assign(:active_skill_count, skill_count())
      |> assign(:time_window_minutes, 60)
      |> assign(:selected_event, nil)
      |> assign(:hidden_categories, MapSet.new())
      |> assign(:filter_categories, @categories)
      |> assign(:show_empty_lanes, false)
      |> load_events()

    {:ok, socket |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  # ---- Render --------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <.sidebar_nav current_path="/timeline" skill_count={@active_skill_count} />

      <%!-- Main column --%>
      <div id="main-content" class="flex-1 flex flex-col overflow-hidden min-w-0">
        <%!-- Top bar --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0 relative z-10">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Session Timeline</h2>
            <div class="badge badge-sm badge-ghost">
              {total_visible_events(@swim_lanes, @hidden_categories)} events
            </div>
          </div>
          <div class="flex items-center gap-2">
            <%!-- Time window selector --%>
            <div class="join">
              <button
                :for={{label, mins} <- [{"15m", 15}, {"30m", 30}, {"1h", 60}, {"6h", 360}, {"24h", 1440}]}
                class={[
                  "join-item btn btn-xs",
                  @time_window_minutes == mins && "btn-primary",
                  @time_window_minutes != mins && "btn-ghost"
                ]}
                phx-click="set_time_window"
                phx-value-minutes={mins}
              >
                {label}
              </button>
            </div>
            <button
              class={[
                "btn btn-xs",
                @show_empty_lanes && "btn-primary",
                !@show_empty_lanes && "btn-ghost"
              ]}
              phx-click="toggle_empty_lanes"
              title="Toggle visibility of lanes with no events in the selected window"
            >
              <.icon name={if @show_empty_lanes, do: "hero-eye", else: "hero-eye-slash"} class="size-3" />
              {empty_lane_count(@swim_lanes)} empty
            </button>
            <button class="btn btn-ghost btn-xs" phx-click="refresh">
              <.icon name="hero-arrow-path" class="size-3" />
              Refresh
            </button>
          </div>
        </header>

        <%!-- Body: swim lanes + optional drill-down --%>
        <div class="flex-1 flex overflow-hidden">
          <%!-- Swim lanes --%>
          <div class="flex-1 overflow-y-auto p-4 space-y-1 min-w-0">
            <.live_region id="timeline-status" politeness="polite">
              <p class="text-xs text-base-content/40 mb-3">
                Showing events from the last {window_label(@time_window_minutes)} — click any dot to inspect
              </p>
            </.live_region>

            <%!-- Time ruler --%>
            <.time_ruler window_minutes={@time_window_minutes} />

            <%!-- One row per category (empty lanes hidden unless toggled) --%>
            <.swim_lane
              :for={lane <- visible_lanes(@swim_lanes, @show_empty_lanes)}
              lane={lane}
              hidden={MapSet.member?(@hidden_categories, lane.category)}
              selected_event={@selected_event}
            />
          </div>

          <%!-- Drill-down panel (slide-in) --%>
          <.drill_down_panel
            :if={@selected_event != nil}
            event={find_event(@swim_lanes, @selected_event)}
          />
        </div>
      </div>
    </div>
    <.wizard page="agents" dom_id="ccem-wizard-agents-timeline" />
    """
  end

  # ---- Sub-components ------------------------------------------------------

  attr :window_minutes, :integer, required: true

  defp time_ruler(assigns) do
    ~H"""
    <div class="flex items-center mb-1 pl-28 pr-2">
      <div class="flex-1 relative h-4">
        <span
          :for={{label, pct} <- ruler_ticks(@window_minutes)}
          class="absolute text-[10px] text-base-content/30 transform -translate-x-1/2"
          style={"left: #{pct}%"}
        >
          {label}
        </span>
      </div>
    </div>
    """
  end

  attr :lane, :map, required: true
  attr :hidden, :boolean, required: true
  attr :selected_event, :string

  defp swim_lane(assigns) do
    ~H"""
    <div class={[
      "flex items-stretch gap-2 rounded transition-opacity duration-150",
      @hidden && "opacity-30"
    ]}>
      <%!-- Lane label + toggle --%>
      <button
        class="w-24 flex-shrink-0 flex flex-col items-end justify-center pr-2 py-2 text-right group"
        phx-click="toggle_lane"
        phx-value-category={@lane.category}
        title={"Toggle #{@lane.category} lane"}
      >
        <span class={["text-xs font-semibold capitalize", lane_label_color(@lane.category)]}>
          {@lane.category}
        </span>
        <span class="text-[10px] text-base-content/40 group-hover:text-base-content/70 transition-colors">
          {@lane.count} events
        </span>
      </button>

      <%!-- Track --%>
      <div class="flex-1 relative h-10 bg-base-300/40 rounded border border-base-300/60 my-1">
        <%!-- Gridlines at 25%, 50%, 75% --%>
        <span
          :for={pct <- [25, 50, 75]}
          class="absolute top-0 bottom-0 w-px bg-base-300/60"
          style={"left: #{pct}%"}
        />

        <%!-- Event dots --%>
        <button
          :for={evt <- @lane.events}
          class={[
            "absolute top-1/2 -translate-y-1/2 -translate-x-1/2 rounded-full border-2 transition-transform hover:scale-150",
            "focus:outline-none focus:ring-1 focus:ring-primary",
            event_dot_size(evt),
            event_dot_color(evt),
            @selected_event == evt.id && "ring-2 ring-primary scale-125"
          ]}
          style={"left: #{evt.position_pct}%"}
          phx-click="select_event"
          phx-value-id={evt.id}
          title={event_tooltip(evt)}
          aria-label={"Event: #{evt.event_type} at #{evt.timestamp}"}
        />
      </div>
    </div>
    """
  end

  attr :event, :map

  defp drill_down_panel(assigns) do
    ~H"""
    <div
      class="w-80 flex-shrink-0 bg-base-200 border-l border-base-300 flex flex-col overflow-hidden"
      role="complementary"
      aria-label="Event detail panel"
    >
      <%!-- Panel header --%>
      <div class="flex items-center justify-between px-3 py-2 border-b border-base-300 flex-shrink-0">
        <span class="text-xs font-semibold text-base-content">Event Detail</span>
        <button
          class="btn btn-ghost btn-xs"
          phx-click="close_event"
          aria-label="Close event detail panel"
        >
          <.icon name="hero-x-mark" class="size-3" />
        </button>
      </div>

      <%!-- Panel body --%>
      <div class="flex-1 overflow-y-auto p-3 space-y-3 text-xs">
        <%= if @event do %>
          <%!-- Type + status badge --%>
          <div class="flex items-center gap-2 flex-wrap">
            <span class={["badge badge-sm", event_status_badge(@event)]}>
              {event_status_label(@event)}
            </span>
            <span class={["badge badge-sm badge-outline capitalize", lane_badge_color(categorize(@event.event_type))]}>
              {categorize(@event.event_type)}
            </span>
          </div>

          <%!-- Core fields --%>
          <table class="w-full text-xs">
            <tbody>
              <.detail_row label="Event type" value={to_string(@event.event_type)} />
              <.detail_row label="Actor" value={@event.actor} />
              <.detail_row label="Resource" value={@event.resource} />
              <.detail_row label="Timestamp" value={@event.timestamp} />
              <%= if @event.correlation_id do %>
                <.detail_row label="Correlation" value={@event.correlation_id} />
              <% end %>
            </tbody>
          </table>

          <%!-- Details map --%>
          <%= if map_size(@event.details || %{}) > 0 do %>
            <div>
              <p class="font-semibold text-base-content/60 mb-1 uppercase tracking-wide text-[10px]">Details</p>
              <div class="bg-base-300/50 rounded p-2 space-y-1 font-mono break-all">
                <div :for={{k, v} <- Map.to_list(@event.details || %{})}>
                  <span class="text-primary/80">{k}</span>
                  <span class="text-base-content/50">: </span>
                  <span class="text-base-content/80">{inspect(v)}</span>
                </div>
              </div>
            </div>
          <% end %>
        <% else %>
          <p class="text-base-content/40 italic">Event not found</p>
        <% end %>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp detail_row(assigns) do
    ~H"""
    <tr class="align-top">
      <td class="pr-2 py-0.5 text-base-content/50 whitespace-nowrap font-medium w-24">{@label}</td>
      <td class="py-0.5 text-base-content/80 break-all">{@value}</td>
    </tr>
    """
  end

  # ---- Event Handlers ------------------------------------------------------

  @impl true
  def handle_event("toggle_lane", %{"category" => cat}, socket) do
    hidden = socket.assigns.hidden_categories

    new_hidden =
      if MapSet.member?(hidden, cat),
        do: MapSet.delete(hidden, cat),
        else: MapSet.put(hidden, cat)

    {:noreply, assign(socket, hidden_categories: new_hidden)}
  end

  def handle_event("select_event", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected_event: id)}
  end

  def handle_event("close_event", _params, socket) do
    {:noreply, assign(socket, selected_event: nil)}
  end

  def handle_event("toggle_empty_lanes", _params, socket) do
    {:noreply, assign(socket, show_empty_lanes: !socket.assigns.show_empty_lanes)}
  end

  def handle_event("set_time_window", %{"minutes" => mins}, socket) do
    socket =
      socket
      |> assign(:time_window_minutes, String.to_integer(mins))
      |> load_events()

    {:noreply, socket}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_events(socket)}
  end

  # ---- PubSub Handlers -----------------------------------------------------

  @impl true
  def handle_info({:agent_registered, _agent}, socket), do: {:noreply, load_events(socket)}
  def handle_info({:agent_updated, _agent}, socket), do: {:noreply, load_events(socket)}
  def handle_info({:audit_event, _event}, socket), do: {:noreply, load_events(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---- Private: data loading -----------------------------------------------

  defp load_events(socket) do
    window_minutes = socket.assigns[:time_window_minutes] || 60
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -window_minutes * 60, :second)
    cutoff_iso = DateTime.to_iso8601(cutoff)

    # Pull recent audit events within the window
    raw_events =
      try do
        AuditLog.query(since: cutoff_iso, limit: 500)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    # Synthesize lifecycle events from agent registry when audit log is sparse
    agent_events = agent_lifecycle_events(AgentRegistry.list_agents(), cutoff, now)
    all_events = raw_events ++ agent_events

    swim_lanes = build_swim_lanes(all_events, cutoff, now)
    assign(socket, :swim_lanes, swim_lanes)
  end

  defp agent_lifecycle_events(agents, cutoff, now) do
    Enum.flat_map(agents, fn agent ->
      registered_at = parse_dt(agent[:registered_at] || agent[:registered_at])

      if registered_at && DateTime.compare(registered_at, cutoff) != :lt do
        [%{
          id: "agent-reg-#{agent.id}",
          timestamp: DateTime.to_iso8601(registered_at),
          event_type: "agent_registered",
          actor: agent.id,
          resource: agent.id,
          details: %{
            name: agent[:name] || agent.id,
            status: agent[:status],
            project: agent[:project_name]
          },
          correlation_id: nil
        }]
      else
        []
      end
    end)
    |> Enum.filter(fn e ->
      dt = parse_dt(e.timestamp)
      dt && DateTime.compare(dt, now) != :gt
    end)
  end

  # ---- Private: swim lane building -----------------------------------------

  defp build_swim_lanes(events, cutoff, now) do
    window_ms = DateTime.diff(now, cutoff, :millisecond)

    grouped =
      Enum.group_by(events, fn evt ->
        categorize(Map.get(evt, :event_type) || Map.get(evt, "event_type", ""))
      end)

    Enum.map(@categories, fn cat ->
      cat_events = Map.get(grouped, cat, [])

      positioned =
        cat_events
        |> Enum.map(fn evt ->
          ts_str = Map.get(evt, :timestamp) || Map.get(evt, "timestamp", "")
          dt = parse_dt(ts_str)

          position_pct =
            if dt && window_ms > 0 do
              offset_ms = DateTime.diff(dt, cutoff, :millisecond)
              pct = offset_ms / window_ms * 100
              Float.round(max(0.0, min(99.0, pct)), 2)
            else
              50.0
            end

          # Normalise keys to atoms
          %{
            id: to_string(Map.get(evt, :id) || Map.get(evt, "id", "evt-#{:erlang.unique_integer()}")),
            timestamp: ts_str,
            event_type: to_string(Map.get(evt, :event_type) || Map.get(evt, "event_type", "")),
            actor: to_string(Map.get(evt, :actor) || Map.get(evt, "actor", "")),
            resource: to_string(Map.get(evt, :resource) || Map.get(evt, "resource", "")),
            details: Map.get(evt, :details) || Map.get(evt, "details") || %{},
            correlation_id: Map.get(evt, :correlation_id) || Map.get(evt, "correlation_id"),
            position_pct: position_pct,
            category: cat
          }
        end)
        |> Enum.sort_by(& &1.position_pct)

      %{
        category: cat,
        events: positioned,
        count: length(positioned)
      }
    end)
  end

  # ---- Private: categorisation ---------------------------------------------

  defp categorize(event_type) do
    type_str = to_string(event_type)

    Enum.find_value(@category_patterns, "system", fn {cat, prefixes} ->
      if Enum.any?(prefixes, &String.contains?(type_str, &1)), do: cat, else: nil
    end)
  end

  # ---- Private: styling helpers --------------------------------------------

  defp event_dot_color(%{event_type: type}) do
    type_str = to_string(type)
    cond do
      String.contains?(type_str, ["error", "denied", "blocked", "rate_limit", "failed"]) ->
        "bg-error border-error/60"
      String.contains?(type_str, ["escalated", "warning", "pending", "timeout"]) ->
        "bg-warning border-warning/60"
      String.contains?(type_str, ["granted", "approved", "success", "finished", "complete"]) ->
        "bg-success border-success/60"
      String.contains?(type_str, ["auth", "agentlock"]) ->
        "bg-secondary border-secondary/60"
      true ->
        "bg-primary border-primary/60"
    end
  end

  defp event_dot_size(%{event_type: type}) do
    type_str = to_string(type)
    if String.contains?(type_str, ["error", "denied", "escalated"]),
      do: "w-3 h-3",
      else: "w-2.5 h-2.5"
  end

  defp event_status_badge(%{event_type: type}) do
    type_str = to_string(type)
    cond do
      String.contains?(type_str, ["error", "denied", "blocked", "failed"]) -> "badge-error"
      String.contains?(type_str, ["escalated", "warning", "pending"]) -> "badge-warning"
      String.contains?(type_str, ["granted", "approved", "success", "complete", "finished"]) -> "badge-success"
      true -> "badge-info"
    end
  end

  defp event_status_label(%{event_type: type}) do
    type_str = to_string(type)
    cond do
      String.contains?(type_str, ["error", "failed"]) -> "error"
      String.contains?(type_str, ["denied", "blocked"]) -> "denied"
      String.contains?(type_str, ["escalated", "pending"]) -> "pending"
      String.contains?(type_str, ["granted", "approved"]) -> "approved"
      String.contains?(type_str, ["success", "complete", "finished"]) -> "ok"
      true -> "info"
    end
  end

  defp visible_lanes(lanes, true), do: lanes
  defp visible_lanes(lanes, false), do: Enum.reject(lanes, fn lane -> lane.count == 0 end)

  defp empty_lane_count(lanes), do: Enum.count(lanes, fn lane -> lane.count == 0 end)

  defp lane_label_color("lifecycle"), do: "text-primary"
  defp lane_label_color("auth"),      do: "text-secondary"
  defp lane_label_color("formation"), do: "text-accent"
  defp lane_label_color("task"),      do: "text-info"
  defp lane_label_color("tool"),      do: "text-warning"
  defp lane_label_color("system"),    do: "text-base-content/60"
  defp lane_label_color(_),           do: "text-base-content/60"

  defp lane_badge_color("lifecycle"), do: "badge-primary"
  defp lane_badge_color("auth"),      do: "badge-secondary"
  defp lane_badge_color("formation"), do: "badge-accent"
  defp lane_badge_color("task"),      do: "badge-info"
  defp lane_badge_color("tool"),      do: "badge-warning"
  defp lane_badge_color(_),           do: "badge-ghost"

  defp event_tooltip(%{event_type: type, actor: actor, timestamp: ts}) do
    "#{type} | #{actor} | #{String.slice(to_string(ts), 0, 19)}"
  end

  # ---- Private: ruler ticks ------------------------------------------------

  defp ruler_ticks(window_minutes) do
    now = DateTime.utc_now()
    # Produce 5 evenly-spaced labels: 0%, 25%, 50%, 75%, 100%
    Enum.map([0, 25, 50, 75, 100], fn pct ->
      offset_seconds = trunc(window_minutes * 60 * pct / 100)
      dt = DateTime.add(now, -(window_minutes * 60) + offset_seconds, :second)
      label = Calendar.strftime(dt, "%H:%M")
      {label, pct}
    end)
  end

  # ---- Private: aggregation helpers ----------------------------------------

  defp total_visible_events(swim_lanes, hidden_categories) do
    swim_lanes
    |> Enum.reject(fn lane -> MapSet.member?(hidden_categories, lane.category) end)
    |> Enum.reduce(0, fn lane, acc -> acc + lane.count end)
  end

  defp find_event(swim_lanes, event_id) do
    swim_lanes
    |> Enum.flat_map(& &1.events)
    |> Enum.find(fn e -> e.id == event_id end)
  end

  defp window_label(mins) when mins < 60, do: "#{mins} minutes"
  defp window_label(60), do: "1 hour"
  defp window_label(360), do: "6 hours"
  defp window_label(1440), do: "24 hours"
  defp window_label(mins), do: "#{div(mins, 60)} hours"

  # ---- Private: DateTime parsing -------------------------------------------

  defp parse_dt(nil), do: nil
  defp parse_dt(""), do: nil

  defp parse_dt(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_dt(%DateTime{} = dt), do: dt
  defp parse_dt(_), do: nil

  # ---- Private: skill count ------------------------------------------------

  defp skill_count do
    try do
      map_size(ApmV5.SkillTracker.get_skill_catalog())
    catch
      :exit, _ -> 0
    end
  end
end
