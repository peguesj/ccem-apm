defmodule ApmV5Web.SessionTimelineLive do
  @moduledoc """
  Observe — Timeline LiveView (CP-180 / US-455).

  Swim-lane timeline displaying one row per agent, with horizontal bars for
  active session periods rendered via the `SessionTimeline` D3.js hook. The
  time window (15m / 1h / 6h / 24h) is server-controlled; PubSub pushes
  reload signals on agent and conversation updates.

  ## Layout
  - `<.page_layout>` three-zone shell (sidebar / main / inspector)
  - Top bar with time-window `<.segmented_control>`
  - Four `<.stat_tile>` metric cards: Active Sessions, Events, Avg Duration, Peak Agents
  - SVG swim-lane chart driven by `SessionTimeline` D3 hook
  - Right `<.inspector_panel>` slides open on event selection
  """

  use ApmV5Web, :live_view

  alias ApmV5.AgentRegistry
  alias ApmV5.AuditLog

  @pubsub_topic_agents "apm:agents"
  @pubsub_topic_conversations "apm:conversations"
  @pubsub_topic_audit "apm:audit"

  @refresh_ms 10_000

  # Six semantic swim-lane categories (order defines display order).
  @categories ~w(lifecycle auth formation task tool system)

  # Prefix patterns that map an event_type string to a category.
  # Order matters — first match wins; "system" is the catch-all.
  @category_patterns [
    {"lifecycle", ["agent_register", "agent_update", "ag_ui.run_started", "ag_ui.run_finished",
                   "ag_ui.run_error", "register", "deregister", "session"]},
    {"auth",      ["auth", "agentlock", "ag_ui.approval", "authorization", "token", "rate_limit"]},
    {"formation", ["formation", "fmt", "squadron", "swarm", "cluster", "orchestrat"]},
    {"task",      ["task", "bg_task", "background", "action"]},
    {"tool",      ["tool", "ag_ui.tool", "TOOL_CALL", "call_start", "call_end", "call_args"]},
    {"system",    []}
  ]

  # ---------------------------------------------------------------------------
  # mount/3
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic_agents)
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic_conversations)
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic_audit)
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    socket =
      socket
      |> assign(
        page_title: "Timeline",
        active_nav: :timeline,
        window: "1h",
        sidebar_collapsed: false,
        inspector_open: false,
        inspector_mode: "selection",
        selected_event: nil,
        hidden_categories: MapSet.new(),
        show_empty_lanes: false,
        categories: @categories
      )
      |> load_timeline_data()
      |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # handle_info/2
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load_timeline_data(socket)}
  end

  def handle_info({:agent_registered, _agent}, socket), do: {:noreply, load_timeline_data(socket)}
  def handle_info({:agent_updated, _agent}, socket), do: {:noreply, load_timeline_data(socket)}
  def handle_info({:audit_event, _event}, socket), do: {:noreply, load_timeline_data(socket)}
  def handle_info({:conversation_updated, _}, socket), do: {:noreply, load_timeline_data(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # handle_event/3
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("switch_window", %{"window" => window}, socket) do
    socket =
      socket
      |> assign(:window, window)
      |> load_timeline_data()

    {:noreply, socket}
  end

  def handle_event("select_event", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected_event: id, inspector_open: true, inspector_mode: "selection")}
  end

  def handle_event("close_event", _params, socket) do
    {:noreply, assign(socket, selected_event: nil, inspector_open: false)}
  end

  def handle_event("toggle_lane", %{"category" => cat}, socket) do
    hidden = socket.assigns.hidden_categories

    new_hidden =
      if MapSet.member?(hidden, cat),
        do: MapSet.delete(hidden, cat),
        else: MapSet.put(hidden, cat)

    {:noreply, assign(socket, hidden_categories: new_hidden)}
  end

  def handle_event("toggle_empty_lanes", _params, socket) do
    {:noreply, assign(socket, show_empty_lanes: !socket.assigns.show_empty_lanes)}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_collapsed: !socket.assigns.sidebar_collapsed)}
  end

  def handle_event("toggle_inspector", _params, socket) do
    {:noreply, assign(socket, inspector_open: !socket.assigns.inspector_open)}
  end

  def handle_event("inspector_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, inspector_mode: mode)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_timeline_data(socket)}
  end

  # ---------------------------------------------------------------------------
  # render/1
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:visible_lanes, visible_lanes(assigns.swim_lanes, assigns.show_empty_lanes))
      |> assign(:total_events, total_visible_events(assigns.swim_lanes, assigns.hidden_categories))

    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav current_path="/timeline" />
      </:sidebar>

      <:topbar>
        <.top_bar project_name="CCEM APM" />
      </:topbar>

      <:main>
        <%!-- Page header --%>
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px; flex-wrap: wrap; gap: 10px;">
          <div style="display: flex; align-items: baseline; gap: 10px;">
            <h1 style="margin: 0; font-size: 16px; font-weight: 600; color: var(--ccem-fg);">
              Timeline
            </h1>
            <span style="font-size: 12px; color: var(--ccem-fg-dim);">
              {@total_events} events · last {@window}
            </span>
          </div>

          <%!-- Time-window segmented control --%>
          <div style="display: flex; align-items: center; gap: 10px;">
            <.segmented_control
              options={["15m", "1h", "6h", "24h"]}
              active={@window}
              on_change="switch_window"
            />
            <button
              phx-click="toggle_empty_lanes"
              style={
                "padding: 4px 10px; font-size: 11px; font-weight: 500; border-radius: 5px; cursor: pointer; border: 1px solid var(--ccem-line); " <>
                  if(@show_empty_lanes,
                    do: "background: var(--ccem-bg-3); color: var(--ccem-fg);",
                    else: "background: transparent; color: var(--ccem-fg-dim);"
                  )
              }
              title="Toggle empty swim lanes"
            >
              {empty_lane_count(@swim_lanes)} empty
            </button>
            <button
              phx-click="refresh"
              style="display: flex; align-items: center; gap: 5px; padding: 4px 10px; font-size: 11px; border-radius: 5px; cursor: pointer; background: transparent; border: 1px solid var(--ccem-line); color: var(--ccem-fg-dim);"
              title="Refresh"
            >
              Refresh
            </button>
          </div>
        </div>

        <%!-- Stat tiles --%>
        <div style="display: flex; gap: 12px; margin-bottom: 20px; flex-wrap: wrap;">
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Active Sessions" value={to_string(@stats.active_sessions)} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Events" value={to_string(@stats.total_events)} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Avg Duration" value={@stats.avg_duration} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Peak Agents" value={to_string(@stats.peak_agents)} />
          </.card>
        </div>

        <%!-- Time ruler --%>
        <div style="display: flex; margin-bottom: 4px; padding-left: 112px; padding-right: 8px;">
          <div style="flex: 1; position: relative; height: 16px;">
            <span
              :for={{label, pct} <- ruler_ticks(@window)}
              style={"position: absolute; font-size: 10px; color: var(--ccem-fg-dim); transform: translateX(-50%); left: #{pct}%;"}
            >
              {label}
            </span>
          </div>
        </div>

        <%!-- Swim lanes --%>
        <div style="display: flex; flex-direction: column; gap: 4px;">
          <p style="font-size: 11px; color: var(--ccem-fg-dim); margin: 0 0 8px 0;">
            Showing events from the last {window_label(@window)} — click any dot to inspect
          </p>

          <%= if @visible_lanes == [] do %>
            <div style="display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 48px 16px; color: var(--ccem-fg-dim);">
              <svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" fill="none" viewBox="0 0 24 24" stroke="currentColor" style="opacity: 0.3; margin-bottom: 10px;">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
              <p style="font-size: 13px; font-weight: 500; margin: 0 0 4px;">No events in this window</p>
              <p style="font-size: 11px; margin: 0; opacity: 0.6;">Try a wider time window or enable empty lanes.</p>
            </div>
          <% else %>
            <.swim_lane
              :for={lane <- @visible_lanes}
              lane={lane}
              hidden={MapSet.member?(@hidden_categories, lane.category)}
              selected_event={@selected_event}
            />
          <% end %>
        </div>

        <%!-- D3 Gantt chart (agent-level swim lanes from SessionTimeline hook) --%>
        <.card style="margin-top: 20px; padding: 0; overflow: hidden;">
          <div style="padding: 10px 14px; border-bottom: 1px solid var(--ccem-line-subtle); display: flex; align-items: center; justify-content: space-between;">
            <span style="font-size: 12px; font-weight: 600; color: var(--ccem-fg);">Agent Activity</span>
            <.badge tone="neutral">{@stats.peak_agents} agents</.badge>
          </div>
          <div
            id="session-timeline-chart"
            phx-hook="SessionTimeline"
            phx-update="ignore"
            style="height: 220px; width: 100%; position: relative;"
          >
          </div>
        </.card>
      </:main>

      <:inspector>
        <.inspector_panel
          open={@inspector_open}
          mode={@inspector_mode}
          on_close="toggle_inspector"
        >
          <:selection>
            <%= if evt = find_event(@swim_lanes, @selected_event) do %>
              <div style="display: flex; flex-direction: column; gap: 12px;">
                <%!-- Type + category badges --%>
                <div style="display: flex; gap: 6px; flex-wrap: wrap;">
                  <.badge tone={event_tone(evt)}>{event_status_label(evt)}</.badge>
                  <.badge tone={category_tone(evt.category)}>{evt.category}</.badge>
                </div>

                <%!-- Core fields --%>
                <div style="display: flex; flex-direction: column; gap: 8px;">
                  <.inspector_row label="Event type" value={to_string(evt.event_type)} mono />
                  <.inspector_row label="Actor" value={to_string(evt.actor)} />
                  <.inspector_row label="Resource" value={to_string(evt.resource)} />
                  <.inspector_row label="Timestamp" value={String.slice(to_string(evt.timestamp), 0, 19)} mono />
                  <%= if evt.correlation_id do %>
                    <.inspector_row label="Correlation" value={to_string(evt.correlation_id)} mono />
                  <% end %>
                </div>

                <%!-- Details map --%>
                <%= if map_size(evt.details || %{}) > 0 do %>
                  <div>
                    <div style="font-size: 10px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--ccem-fg-dim); margin-bottom: 6px;">Details</div>
                    <div style="background: var(--ccem-bg-2); border-radius: 5px; padding: 8px; font-family: var(--ccem-font-mono, monospace); font-size: 11px; word-break: break-all; display: flex; flex-direction: column; gap: 4px;">
                      <div :for={{k, v} <- Map.to_list(evt.details || %{})}>
                        <span style="color: var(--ccem-accent);">{k}</span>
                        <span style="color: var(--ccem-fg-dim);">: </span>
                        <span style="color: var(--ccem-fg);">{inspect(v)}</span>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            <% else %>
              <p style="font-size: 13px; color: var(--ccem-fg-dim); margin: 0;">
                Select an event to view details.
              </p>
            <% end %>
          </:selection>

          <:copilot>
            <p style="font-size: 13px; color: var(--ccem-fg-dim); margin: 0;">
              Timeline AI co-pilot coming soon.
            </p>
          </:copilot>

          <:filters>
            <div style="display: flex; flex-direction: column; gap: 12px;">
              <div>
                <div style="font-size: 11px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--ccem-fg-dim); margin-bottom: 6px;">
                  Time Window
                </div>
                <.segmented_control
                  options={["15m", "1h", "6h", "24h"]}
                  active={@window}
                  on_change="switch_window"
                />
              </div>
              <div>
                <div style="font-size: 11px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--ccem-fg-dim); margin-bottom: 6px;">
                  Lanes
                </div>
                <div style="display: flex; flex-direction: column; gap: 4px;">
                  <%= for cat <- @categories do %>
                    <button
                      phx-click="toggle_lane"
                      phx-value-category={cat}
                      style={
                        "text-align: left; padding: 4px 8px; font-size: 12px; border-radius: 4px; cursor: pointer; border: none; " <>
                          if(MapSet.member?(@hidden_categories, cat),
                            do: "background: transparent; color: var(--ccem-fg-muted); opacity: 0.5;",
                            else: "background: var(--ccem-bg-3); color: var(--ccem-fg); font-weight: 500;"
                          )
                      }
                    >
                      {cat}
                    </button>
                  <% end %>
                </div>
              </div>
            </div>
          </:filters>
        </.inspector_panel>
      </:inspector>
    </.page_layout>
    """
  end

  # ---------------------------------------------------------------------------
  # Private components
  # ---------------------------------------------------------------------------

  attr :lane, :map, required: true
  attr :hidden, :boolean, required: true
  attr :selected_event, :string, default: nil

  defp swim_lane(assigns) do
    ~H"""
    <div style={
      "display: flex; align-items: stretch; gap: 8px; border-radius: 6px; " <>
        if(@hidden, do: "opacity: 0.3;", else: "")
    }>
      <%!-- Lane label + toggle --%>
      <button
        phx-click="toggle_lane"
        phx-value-category={@lane.category}
        title={"Toggle #{@lane.category} lane"}
        style="width: 100px; flex-shrink: 0; display: flex; flex-direction: column; align-items: flex-end; justify-content: center; padding-right: 8px; background: transparent; border: none; cursor: pointer; text-align: right;"
      >
        <span style={"font-size: 11px; font-weight: 600; text-transform: capitalize; #{lane_label_style(@lane.category)}"}>
          {@lane.category}
        </span>
        <span style="font-size: 10px; color: var(--ccem-fg-dim);">
          {@lane.count} events
        </span>
      </button>

      <%!-- Track --%>
      <div style="flex: 1; position: relative; height: 36px; background: var(--ccem-bg-2); border-radius: 5px; border: 1px solid var(--ccem-line-subtle); margin: 4px 0;">
        <%!-- Grid lines at 25%, 50%, 75% --%>
        <span
          :for={pct <- [25, 50, 75]}
          style={"position: absolute; top: 0; bottom: 0; width: 1px; background: var(--ccem-line-subtle); left: #{pct}%;"}
        />

        <%!-- Event dots --%>
        <button
          :for={evt <- @lane.events}
          phx-click="select_event"
          phx-value-id={evt.id}
          title={event_tooltip(evt)}
          aria-label={"Event: #{evt.event_type} at #{evt.timestamp}"}
          style={
            "position: absolute; top: 50%; transform: translate(-50%, -50%); " <>
              "width: #{if String.contains?(to_string(evt.event_type), ["error", "denied", "escalated"]), do: "12px", else: "10px"}; " <>
              "height: #{if String.contains?(to_string(evt.event_type), ["error", "denied", "escalated"]), do: "12px", else: "10px"}; " <>
              "border-radius: 50%; cursor: pointer; border: 2px solid; " <>
              "left: #{evt.position_pct}%; " <>
              event_dot_style(evt) <>
              if(@selected_event == evt.id, do: " outline: 2px solid var(--ccem-accent); outline-offset: 2px;", else: "")
          }
        />
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :mono, :boolean, default: false

  defp inspector_row(assigns) do
    ~H"""
    <div style="display: flex; justify-content: space-between; align-items: baseline; gap: 8px;">
      <span style="font-size: 11px; color: var(--ccem-fg-dim); flex-shrink: 0;">{@label}</span>
      <span style={
        "font-size: 12px; color: var(--ccem-fg); text-align: right; word-break: break-all; " <>
          if(@mono, do: "font-family: var(--ccem-font-mono, monospace); font-variant-numeric: tabular-nums;", else: "")
      }>
        {@value}
      </span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private: data loading
  # ---------------------------------------------------------------------------

  @spec load_timeline_data(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_timeline_data(socket) do
    window = socket.assigns[:window] || "1h"
    window_minutes = window_to_minutes(window)
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -window_minutes * 60, :second)
    cutoff_iso = DateTime.to_iso8601(cutoff)

    raw_events =
      try do
        AuditLog.query(since: cutoff_iso, limit: 500)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    agents =
      try do
        AgentRegistry.list_agents()
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    agent_events = build_agent_lifecycle_events(agents, cutoff, now)
    all_events = raw_events ++ agent_events

    swim_lanes = build_swim_lanes(all_events, cutoff, now)
    stats = compute_stats(agents, all_events, window_minutes)

    timeline_entries = build_timeline_entries(agents, cutoff, now)

    socket
    |> assign(:swim_lanes, swim_lanes)
    |> assign(:stats, stats)
    |> push_event("timeline_data", %{
      entries: timeline_entries,
      time_range: window,
      cutoff: DateTime.to_iso8601(cutoff),
      now: DateTime.to_iso8601(now)
    })
  end

  @spec build_agent_lifecycle_events([map()], DateTime.t(), DateTime.t()) :: [map()]
  defp build_agent_lifecycle_events(agents, cutoff, now) do
    agents
    |> Enum.flat_map(fn agent ->
      registered_at = parse_dt(agent[:registered_at])

      if registered_at && DateTime.compare(registered_at, cutoff) != :lt do
        [%{
          id: "agent-reg-#{agent.id}",
          timestamp: DateTime.to_iso8601(registered_at),
          event_type: "agent_registered",
          actor: to_string(agent.id),
          resource: to_string(agent.id),
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

  # Build D3-ready agent activity entries for the SessionTimeline hook.
  @spec build_timeline_entries([map()], DateTime.t(), DateTime.t()) :: [map()]
  defp build_timeline_entries(agents, cutoff, now) do
    Enum.map(agents, fn agent ->
      registered_at = parse_dt(agent[:registered_at]) || cutoff
      start_time = if DateTime.compare(registered_at, cutoff) == :lt, do: cutoff, else: registered_at

      %{
        name: truncate(to_string(agent[:name] || agent.id), 20),
        status: to_string(agent[:status] || "idle"),
        start_time: DateTime.to_iso8601(start_time),
        end_time: DateTime.to_iso8601(now),
        tool_calls: Map.get(agent, :tool_calls, 0) || 0
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Private: swim lane construction
  # ---------------------------------------------------------------------------

  @spec build_swim_lanes([map()], DateTime.t(), DateTime.t()) :: [map()]
  defp build_swim_lanes(events, cutoff, now) do
    window_ms = max(DateTime.diff(now, cutoff, :millisecond), 1)

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

          stable_id =
            Map.get(evt, :id) ||
              Map.get(evt, "id") ||
              Map.get(evt, :event_id) ||
              Map.get(evt, "event_id") ||
              Map.get(evt, :request_id) ||
              Map.get(evt, "request_id") ||
              "evt-#{System.unique_integer([:positive])}"

          %{
            id: to_string(stable_id),
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

      %{category: cat, events: positioned, count: length(positioned)}
    end)
  end

  # ---------------------------------------------------------------------------
  # Private: stats computation
  # ---------------------------------------------------------------------------

  @spec compute_stats([map()], [map()], non_neg_integer()) :: map()
  defp compute_stats(agents, events, window_minutes) do
    active_sessions = Enum.count(agents, fn a -> to_string(a[:status]) == "active" end)
    total_events = length(events)
    peak_agents = length(agents)

    avg_duration =
      if peak_agents > 0 do
        avg_mins = div(window_minutes, max(peak_agents, 1))
        format_duration_mins(avg_mins)
      else
        "—"
      end

    %{
      active_sessions: active_sessions,
      total_events: total_events,
      peak_agents: peak_agents,
      avg_duration: avg_duration
    }
  end

  @spec format_duration_mins(integer()) :: String.t()
  defp format_duration_mins(mins) when mins < 1, do: "<1m"
  defp format_duration_mins(mins) when mins < 60, do: "#{mins}m"
  defp format_duration_mins(mins), do: "#{div(mins, 60)}h #{rem(mins, 60)}m"

  # ---------------------------------------------------------------------------
  # Private: categorisation
  # ---------------------------------------------------------------------------

  @spec categorize(String.t() | atom()) :: String.t()
  defp categorize(event_type) do
    type_str = to_string(event_type)

    Enum.find_value(@category_patterns, "system", fn {cat, prefixes} ->
      if Enum.any?(prefixes, &String.contains?(type_str, &1)), do: cat, else: nil
    end)
  end

  # ---------------------------------------------------------------------------
  # Private: ruler helpers
  # ---------------------------------------------------------------------------

  @spec ruler_ticks(String.t()) :: [{String.t(), non_neg_integer()}]
  defp ruler_ticks(window) do
    now = DateTime.utc_now()
    window_minutes = window_to_minutes(window)

    Enum.map([0, 25, 50, 75, 100], fn pct ->
      offset_seconds = trunc(window_minutes * 60 * pct / 100)
      dt = DateTime.add(now, -(window_minutes * 60) + offset_seconds, :second)
      label = Calendar.strftime(dt, "%H:%M")
      {label, pct}
    end)
  end

  # ---------------------------------------------------------------------------
  # Private: lane visibility helpers
  # ---------------------------------------------------------------------------

  @spec visible_lanes([map()], boolean()) :: [map()]
  defp visible_lanes(lanes, true), do: lanes
  defp visible_lanes(lanes, false), do: Enum.reject(lanes, fn l -> l.count == 0 end)

  @spec empty_lane_count([map()]) :: non_neg_integer()
  defp empty_lane_count(lanes), do: Enum.count(lanes, fn l -> l.count == 0 end)

  @spec total_visible_events([map()], MapSet.t()) :: non_neg_integer()
  defp total_visible_events(swim_lanes, hidden_categories) do
    swim_lanes
    |> Enum.reject(fn lane -> MapSet.member?(hidden_categories, lane.category) end)
    |> Enum.reduce(0, fn lane, acc -> acc + lane.count end)
  end

  @spec find_event([map()], String.t() | nil) :: map() | nil
  defp find_event(_lanes, nil), do: nil

  defp find_event(swim_lanes, event_id) do
    swim_lanes
    |> Enum.flat_map(& &1.events)
    |> Enum.find(fn e -> e.id == event_id end)
  end

  # ---------------------------------------------------------------------------
  # Private: styling helpers
  # ---------------------------------------------------------------------------

  @spec event_dot_style(map()) :: String.t()
  defp event_dot_style(%{event_type: type}) do
    type_str = to_string(type)

    cond do
      String.contains?(type_str, ["error", "denied", "blocked", "rate_limit", "failed"]) ->
        "background: var(--ccem-err); border-color: color-mix(in srgb, var(--ccem-err) 60%, transparent);"

      String.contains?(type_str, ["escalated", "warning", "pending", "timeout"]) ->
        "background: var(--ccem-warn); border-color: color-mix(in srgb, var(--ccem-warn) 60%, transparent);"

      String.contains?(type_str, ["granted", "approved", "success", "finished", "complete"]) ->
        "background: var(--ccem-ok); border-color: color-mix(in srgb, var(--ccem-ok) 60%, transparent);"

      String.contains?(type_str, ["auth", "agentlock"]) ->
        "background: var(--ccem-iris); border-color: color-mix(in srgb, var(--ccem-iris) 60%, transparent);"

      true ->
        "background: var(--ccem-accent); border-color: color-mix(in srgb, var(--ccem-accent) 60%, transparent);"
    end
  end

  @spec event_tone(map()) :: String.t()
  defp event_tone(%{event_type: type}) do
    type_str = to_string(type)

    cond do
      String.contains?(type_str, ["error", "denied", "blocked", "failed"]) -> "err"
      String.contains?(type_str, ["escalated", "warning", "pending"]) -> "warn"
      String.contains?(type_str, ["granted", "approved", "success", "complete", "finished"]) -> "ok"
      true -> "neutral"
    end
  end

  @spec event_status_label(map()) :: String.t()
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

  @spec category_tone(String.t()) :: String.t()
  defp category_tone("lifecycle"), do: "ok"
  defp category_tone("auth"), do: "iris"
  defp category_tone("formation"), do: "warn"
  defp category_tone("task"), do: "neutral"
  defp category_tone("tool"), do: "warn"
  defp category_tone(_), do: "neutral"

  @spec lane_label_style(String.t()) :: String.t()
  defp lane_label_style("lifecycle"), do: "color: var(--ccem-accent);"
  defp lane_label_style("auth"), do: "color: var(--ccem-iris);"
  defp lane_label_style("formation"), do: "color: var(--ccem-warn);"
  defp lane_label_style("task"), do: "color: var(--ccem-ok);"
  defp lane_label_style("tool"), do: "color: var(--ccem-ok);"
  defp lane_label_style(_), do: "color: var(--ccem-fg-dim);"

  @spec event_tooltip(map()) :: String.t()
  defp event_tooltip(%{event_type: type, actor: actor, timestamp: ts}) do
    "#{type} | #{actor} | #{String.slice(to_string(ts), 0, 19)}"
  end

  # ---------------------------------------------------------------------------
  # Private: window helpers
  # ---------------------------------------------------------------------------

  @spec window_to_minutes(String.t()) :: pos_integer()
  defp window_to_minutes("15m"), do: 15
  defp window_to_minutes("1h"), do: 60
  defp window_to_minutes("6h"), do: 360
  defp window_to_minutes("24h"), do: 1440
  defp window_to_minutes(_), do: 60

  @spec window_label(String.t()) :: String.t()
  defp window_label("15m"), do: "15 minutes"
  defp window_label("1h"), do: "1 hour"
  defp window_label("6h"), do: "6 hours"
  defp window_label("24h"), do: "24 hours"
  defp window_label(w), do: w

  # ---------------------------------------------------------------------------
  # Private: DateTime parsing
  # ---------------------------------------------------------------------------

  @spec parse_dt(term()) :: DateTime.t() | nil
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

  # ---------------------------------------------------------------------------
  # Private: string helpers
  # ---------------------------------------------------------------------------

  @spec truncate(String.t(), pos_integer()) :: String.t()
  defp truncate(str, max) when byte_size(str) > max, do: String.slice(str, 0, max) <> "…"
  defp truncate(str, _max), do: str
end
