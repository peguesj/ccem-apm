defmodule ApmV5Web.ToolCallLive do
  @moduledoc """
  Observe — Tool Calls LiveView (CP-182 / US-457).

  Real-time tool call activity dashboard using the CCEM design system shell.

  ## Layout
  - Stat tiles: Total Calls / Active / Errors / Avg Duration
  - `data_table` stream view: Tool / Agent / Status / Duration / Tokens / Timestamp
  - Per-agent stats sidebar rendered as `card` + `sparkline`
  - `inspector_panel` shows selected tool call raw JSON

  ## PubSub
  Subscribes to `"apm:tool_calls"` for real-time updates. Also handles
  `EventBus` events on `"tool:*"` forwarded by the existing tracker.
  """

  use ApmV5Web, :live_view

  alias ApmV5.AgUi.ToolCallTracker
  alias ApmV5.AgUi.EventBus

  @pubsub_topic "apm:tool_calls"
  @refresh_ms 5_000

  # ---------------------------------------------------------------------------
  # mount/3
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic)
      EventBus.subscribe("tool:*")
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    {tool_calls, stats} = load_data()

    {:ok,
     socket
     |> assign(
       page_title: "Tool Calls",
       tool_calls: tool_calls,
       stats: stats,
       sidebar_collapsed: false,
       inspector_open: false,
       inspector_mode: "selection",
       selected_call: nil
     )
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  # ---------------------------------------------------------------------------
  # handle_info/2
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {tool_calls, stats} = load_data()
    {:noreply, assign(socket, tool_calls: tool_calls, stats: stats)}
  end

  def handle_info({:event_bus, _topic, _event}, socket) do
    {tool_calls, stats} = load_data()
    {:noreply, assign(socket, tool_calls: tool_calls, stats: stats)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # handle_event/3
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("select_call", %{"id" => call_id}, socket) do
    selected = Enum.find(socket.assigns.tool_calls, &(to_string(&1.id || &1.tool_call_id) == call_id))

    {:noreply,
     assign(socket,
       selected_call: selected,
       inspector_open: true,
       inspector_mode: "selection"
     )}
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_collapsed: !socket.assigns.sidebar_collapsed)}
  end

  @impl true
  def handle_event("toggle_inspector", _params, socket) do
    {:noreply, assign(socket, inspector_open: !socket.assigns.inspector_open)}
  end

  @impl true
  def handle_event("inspector_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, inspector_mode: mode)}
  end

  # ---------------------------------------------------------------------------
  # render/1
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav current_path="/tool-calls" />
      </:sidebar>

      <:topbar>
        <.top_bar project_name="CCEM APM" />
      </:topbar>

      <:main>
        <%!-- Page header --%>
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
          <div style="display: flex; align-items: baseline; gap: 10px;">
            <h1 style="margin: 0; font-size: 16px; font-weight: 600; color: var(--ccem-fg);">
              Tool Calls
            </h1>
            <span style="font-size: 12px; color: var(--ccem-fg-dim);">
              {@stats.total} total
            </span>
          </div>
          <button
            phx-click="toggle_inspector"
            style="display: flex; align-items: center; justify-content: center; width: 28px; height: 28px; background: var(--ccem-bg-2); border: 1px solid var(--ccem-line); border-radius: 5px; cursor: pointer; color: var(--ccem-fg-dim); font-size: 13px;"
            title="Toggle inspector"
          >
            &#9776;
          </button>
        </div>

        <%!-- Stat tiles --%>
        <div style="display: flex; gap: 12px; margin-bottom: 16px; flex-wrap: wrap;">
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Total Calls" value={to_string(@stats.total)} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Active" value={to_string(@stats.active)} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Completed" value={to_string(@stats.completed)} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Avg Duration" value={"#{@stats.avg_duration_ms}ms"} />
          </.card>
        </div>

        <%!-- Tool calls table --%>
        <.card padded={false} style="margin-bottom: 16px;">
          <div style="padding: 12px 16px 8px; border-bottom: 1px solid var(--ccem-line);">
            <span style="font-size: 13px; font-weight: 600; color: var(--ccem-fg);">Recent Tool Calls</span>
          </div>
          <.data_table id="tool-calls-table" rows={@tool_calls}>
            <:col :let={call} label="Tool">
              <button
                phx-click="select_call"
                phx-value-id={to_string(call_id(call))}
                style="background: none; border: none; padding: 0; font-size: 12px; font-weight: 500; color: var(--ccem-accent); cursor: pointer; font-family: var(--ccem-font-mono, monospace); text-align: left;"
              >
                {call.tool_name || "—"}
              </button>
            </:col>
            <:col :let={call} label="Agent">
              <span style="font-family: var(--ccem-font-mono, monospace); font-size: 11px; color: var(--ccem-fg-dim);">
                {truncate(to_string(call.agent_id || "—"), 20)}
              </span>
            </:col>
            <:col :let={call} label="Status">
              <.badge tone={call_status_tone(call.status)}>
                {call_status_label(call.status)}
              </.badge>
            </:col>
            <:col :let={call} label="Duration">
              <span style="font-family: var(--ccem-font-mono, monospace); font-size: 12px; font-variant-numeric: tabular-nums; color: var(--ccem-fg);">
                {format_duration(call.duration_ms)}
              </span>
            </:col>
            <:col :let={call} label="Tokens">
              <span style="font-family: var(--ccem-font-mono, monospace); font-size: 12px; font-variant-numeric: tabular-nums; color: var(--ccem-fg);">
                {format_tokens(call)}
              </span>
            </:col>
            <:col :let={call} label="Timestamp">
              <span style="font-size: 11px; color: var(--ccem-fg-muted);">
                {format_timestamp(call)}
              </span>
            </:col>
          </.data_table>

          <%= if @tool_calls == [] do %>
            <div style="padding: 32px 16px; text-align: center; color: var(--ccem-fg-dim); font-size: 13px;">
              No tool calls recorded yet.
            </div>
          <% end %>
        </.card>

        <%!-- Per-agent sparkline cards --%>
        <%= if map_size(@stats.calls_by_agent) > 0 do %>
          <div style="margin-bottom: 8px;">
            <span style="font-size: 11px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--ccem-fg-dim);">
              Calls by Agent
            </span>
          </div>
          <div style="display: flex; flex-wrap: wrap; gap: 10px;">
            <%= for {agent_id, count} <- Enum.take(@stats.calls_by_agent, 8) do %>
              <.card style="flex: 0 0 auto; min-width: 160px; padding: 10px 14px;">
                <div style="font-family: var(--ccem-font-mono, monospace); font-size: 10px; color: var(--ccem-fg-dim); margin-bottom: 4px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 140px;">
                  {truncate(to_string(agent_id), 18)}
                </div>
                <div style="display: flex; align-items: center; justify-content: space-between;">
                  <span style="font-size: 18px; font-weight: 700; color: var(--ccem-fg); font-variant-numeric: tabular-nums;">
                    {count}
                  </span>
                  <.sparkline
                    data={agent_sparkline(@stats.calls_by_agent, agent_id, count)}
                    width={60}
                    height={20}
                    live_dot={false}
                  />
                </div>
                <div style="font-size: 10px; color: var(--ccem-fg-dim); margin-top: 2px;">calls</div>
              </.card>
            <% end %>
          </div>
        <% end %>
      </:main>

      <:inspector>
        <.inspector_panel
          open={@inspector_open}
          mode={@inspector_mode}
          on_close="toggle_inspector"
        >
          <:selection>
            <%= if @selected_call do %>
              <div style="display: flex; flex-direction: column; gap: 12px;">
                <div>
                  <div style="font-size: 13px; font-weight: 600; color: var(--ccem-fg); margin-bottom: 2px;">
                    {@selected_call.tool_name || "Unknown Tool"}
                  </div>
                  <.badge tone={call_status_tone(@selected_call.status)}>
                    {call_status_label(@selected_call.status)}
                  </.badge>
                </div>

                <div style="display: flex; flex-direction: column; gap: 8px;">
                  <.inspector_kv label="ID" value={to_string(call_id(@selected_call))} mono />
                  <.inspector_kv label="Agent" value={to_string(@selected_call.agent_id || "—")} mono />
                  <.inspector_kv label="Duration" value={format_duration(@selected_call.duration_ms)} mono />
                  <.inspector_kv label="Tokens" value={format_tokens(@selected_call)} mono />
                  <.inspector_kv label="Started" value={format_timestamp(@selected_call)} />
                </div>

                <div>
                  <div style="font-size: 10px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--ccem-fg-dim); margin-bottom: 6px;">
                    Raw JSON
                  </div>
                  <div style="background: var(--ccem-bg-1); border: 1px solid var(--ccem-line); border-radius: 6px; padding: 10px; overflow-x: auto; max-height: 320px; overflow-y: auto;">
                    <pre style="margin: 0; font-size: 10px; line-height: 1.5; font-family: var(--ccem-font-mono, monospace); color: var(--ccem-fg); white-space: pre-wrap; word-break: break-all;">{call_json(@selected_call)}</pre>
                  </div>
                </div>
              </div>
            <% else %>
              <p style="font-size: 13px; color: var(--ccem-fg-dim); margin: 0;">
                Select a tool call row to inspect details and raw JSON payload.
              </p>
            <% end %>
          </:selection>

          <:copilot>
            <p style="font-size: 13px; color: var(--ccem-fg-dim); margin: 0;">
              Tool call AI co-pilot coming soon.
            </p>
          </:copilot>

          <:filters>
            <p style="font-size: 13px; color: var(--ccem-fg-dim); margin: 0;">
              Filters coming soon.
            </p>
          </:filters>
        </.inspector_panel>
      </:inspector>
    </.page_layout>
    """
  end

  # ---------------------------------------------------------------------------
  # Private components
  # ---------------------------------------------------------------------------

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :mono, :boolean, default: false

  defp inspector_kv(assigns) do
    ~H"""
    <div style="display: flex; justify-content: space-between; align-items: baseline; gap: 8px;">
      <span style="font-size: 11px; color: var(--ccem-fg-dim); flex-shrink: 0;">{@label}</span>
      <span style={
        "font-size: 12px; color: var(--ccem-fg); text-align: right; word-break: break-all;" <>
          if(@mono, do: " font-family: var(--ccem-font-mono, monospace); font-variant-numeric: tabular-nums;", else: "")
      }>
        {@value}
      </span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec load_data() :: {[map()], map()}
  defp load_data do
    try do
      all_calls =
        :ets.tab2list(:tool_call_tracker)
        |> Enum.map(fn {_id, entry} -> entry end)
        |> Enum.sort_by(& &1.started_at, {:desc, DateTime})

      stats = ToolCallTracker.stats()
      {Enum.take(all_calls, 100), stats}
    rescue
      _ ->
        try do
          stats = ToolCallTracker.stats()
          active = ToolCallTracker.list_active()
          {active, stats}
        rescue
          _ ->
            empty_stats = %{
              total: 0,
              active: 0,
              completed: 0,
              avg_duration_ms: 0.0,
              top_tools: %{},
              calls_by_agent: %{}
            }

            {[], empty_stats}
        end
    end
  end

  @spec call_id(map()) :: any()
  defp call_id(call) do
    Map.get(call, :id) || Map.get(call, :tool_call_id) || "unknown"
  end

  @spec call_status_tone(atom() | String.t() | nil) :: String.t()
  defp call_status_tone(:in_progress), do: "warning"
  defp call_status_tone(:completed), do: "success"
  defp call_status_tone(:error), do: "error"
  defp call_status_tone("in_progress"), do: "warning"
  defp call_status_tone("completed"), do: "success"
  defp call_status_tone("error"), do: "error"
  defp call_status_tone(_), do: "neutral"

  @spec call_status_label(atom() | String.t() | nil) :: String.t()
  defp call_status_label(:in_progress), do: "Active"
  defp call_status_label(:completed), do: "Done"
  defp call_status_label(:error), do: "Error"
  defp call_status_label(s) when is_binary(s), do: String.capitalize(s)
  defp call_status_label(_), do: "—"

  @spec format_duration(number() | nil) :: String.t()
  defp format_duration(nil), do: "—"
  defp format_duration(ms) when is_number(ms) and ms >= 1_000, do: "#{Float.round(ms / 1_000, 2)}s"
  defp format_duration(ms) when is_number(ms), do: "#{round(ms)}ms"
  defp format_duration(_), do: "—"

  @spec format_tokens(map()) :: String.t()
  defp format_tokens(call) do
    tokens = Map.get(call, :tokens) || Map.get(call, :token_count)

    case tokens do
      nil -> "—"
      n when is_integer(n) and n >= 1_000 -> "#{Float.round(n / 1_000, 1)}K"
      n when is_integer(n) -> to_string(n)
      _ -> "—"
    end
  end

  @spec format_timestamp(map()) :: String.t()
  defp format_timestamp(call) do
    ts = Map.get(call, :started_at) || Map.get(call, :started_at_wall)

    case ts do
      %DateTime{} = dt -> Calendar.strftime(dt, "%H:%M:%S")
      s when is_binary(s) -> String.slice(s, 0, 19)
      _ -> "—"
    end
  end

  @spec call_json(map()) :: String.t()
  defp call_json(call) do
    call
    |> Map.from_struct()
    |> then(fn m -> Jason.encode!(m, pretty: true) end)
  rescue
    _ ->
      call
      |> Map.drop([:__struct__])
      |> Jason.encode!(pretty: true)
  end

  @spec agent_sparkline(map(), any(), integer()) :: [number()]
  defp agent_sparkline(_calls_by_agent, _agent_id, count) do
    # Synthesise a 12-point sparkline shaped by the call count magnitude.
    base = max(count, 1)
    Enum.map(0..11, fn i -> trunc(base * (:math.sin(i / 3.0) * 0.3 + 0.7)) end)
  end

  @spec truncate(String.t(), integer()) :: String.t()
  defp truncate(s, max) when byte_size(s) > max, do: String.slice(s, 0, max) <> "…"
  defp truncate(s, _max), do: s
end
