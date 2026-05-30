defmodule ApmWeb.A2ALive do
  @moduledoc """
  Observe — A2A Messaging LiveView (CP-182 / US-457).

  Agent-to-Agent messaging monitor using the CCEM design system shell.

  ## Layout
  - Stat tiles: Active Routes / Messages/min / Broadcast Groups / Avg Fanout
  - Router table: `data_table` with From / To / Channel / Message Type / Count
  - Broadcast log: recent A2A messages as a scrollable list with `badge` tones
  - Fan-out graph: `<svg phx-hook="GraphForce">` with `graph_node`/`graph_edge` elements

  ## PubSub
  Subscribes to `"apm:a2a"` and `EventBus` `"a2a:*"` for real-time message feed.
  Polls stats every 5 seconds.
  """

  use ApmWeb, :live_view

  alias Apm.AgUi.A2A.Router
  alias Apm.AgUi.EventBus

  @pubsub_topic "apm:a2a"
  @refresh_ms 5_000
  @max_log 50

  # ---------------------------------------------------------------------------
  # mount/3
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Apm.PubSub, @pubsub_topic)
      EventBus.subscribe("a2a:*")
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    stats = safe_stats()
    routes = build_routes(stats)

    {:ok,
     socket
     |> assign(
       page_title: "A2A",
       stats: stats,
       routes: routes,
       broadcast_log: [],
       sidebar_collapsed: false,
       inspector_open: false,
       inspector_mode: "selection"
     )
     |> ApmWeb.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  # ---------------------------------------------------------------------------
  # handle_info/2
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    stats = safe_stats()
    routes = build_routes(stats)
    {:noreply, assign(socket, stats: stats, routes: routes)}
  end

  def handle_info({:event_bus, _topic, event}, socket) do
    log_entry = build_log_entry(event)
    broadcast_log = Enum.take([log_entry | socket.assigns.broadcast_log], @max_log)
    stats = safe_stats()
    routes = build_routes(stats)

    {:noreply, assign(socket, broadcast_log: broadcast_log, stats: stats, routes: routes)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # handle_event/3
  # ---------------------------------------------------------------------------

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
    assigns =
      assign(assigns,
        queue_pairs: build_queue_pairs(assigns.stats),
        graph_nodes: build_graph_nodes(assigns.stats),
        graph_edges: build_graph_edges(assigns.stats)
      )

    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav current_path="/a2a" />
      </:sidebar>

      <:topbar>
        <.top_bar project_name="CCEM APM" />
      </:topbar>

      <:main>
        <%!-- Page header --%>
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
          <div style="display: flex; align-items: baseline; gap: 10px;">
            <h1 style="margin: 0; font-size: 16px; font-weight: 600; color: var(--ccem-fg);">
              A2A Messaging
            </h1>
            <span style="font-size: 12px; color: var(--ccem-fg-dim);">
              Agent-to-Agent
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
            <.stat_tile label="Sent" value={to_string(@stats[:sent_count] || 0)} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Delivered" value={to_string(@stats[:delivered_count] || 0)} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Expired" value={to_string(@stats[:expired_count] || 0)} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Active Queues" value={to_string(map_size(@stats[:queue_depths] || %{}))} />
          </.card>
        </div>

        <%!-- Fan-out graph --%>
        <%= if length(@graph_nodes) > 1 do %>
          <.card style="margin-bottom: 16px; padding: 0; overflow: hidden;">
            <div style="padding: 12px 16px 8px; border-bottom: 1px solid var(--ccem-line);">
              <span style="font-size: 13px; font-weight: 600; color: var(--ccem-fg);">Message Routing Graph</span>
            </div>
            <svg
              id="a2a-graph"
              phx-hook="GraphForce"
              width="100%"
              height="240"
              style="display: block; background: var(--ccem-bg-1);"
            >
              <%= for node <- @graph_nodes do %>
                <.graph_node
                  node_id={node.id}
                  label={node.label}
                  role={node.role}
                  status={node.status}
                />
              <% end %>
              <%= for edge <- @graph_edges do %>
                <.graph_edge
                  edge_id={edge.id}
                  source_id={edge.source_id}
                  target_id={edge.target_id}
                  edge_type={edge.edge_type}
                  live={edge.live}
                />
              <% end %>
            </svg>
          </.card>
        <% end %>

        <%!-- Route table --%>
        <.card padded={false} style="margin-bottom: 16px;">
          <div style="padding: 12px 16px 8px; border-bottom: 1px solid var(--ccem-line);">
            <span style="font-size: 13px; font-weight: 600; color: var(--ccem-fg);">Queue Depths</span>
          </div>
          <.data_table id="a2a-routes-table" rows={@queue_pairs}>
            <:col :let={row} label="Agent">
              <span style="font-family: var(--ccem-font-mono, monospace); font-size: 11px; color: var(--ccem-fg);">
                {row.agent_id}
              </span>
            </:col>
            <:col label="Channel">
              <.badge tone="iris">a2a</.badge>
            </:col>
            <:col label="Message Type">
              <span style="font-size: 12px; color: var(--ccem-fg-dim);">queued</span>
            </:col>
            <:col :let={row} label="Pending">
              <.badge tone={if row.depth > 0, do: "warning", else: "neutral"}>
                {row.depth}
              </.badge>
            </:col>
          </.data_table>

          <%= if @queue_pairs == [] do %>
            <div style="padding: 24px 16px; text-align: center; color: var(--ccem-fg-dim); font-size: 13px;">
              No active agent queues.
            </div>
          <% end %>
        </.card>

        <%!-- Broadcast log --%>
        <.card padded={false}>
          <div style="padding: 12px 16px 8px; border-bottom: 1px solid var(--ccem-line); display: flex; align-items: center; justify-content: space-between;">
            <span style="font-size: 13px; font-weight: 600; color: var(--ccem-fg);">
              Live Message Feed
            </span>
            <span style="font-size: 11px; color: var(--ccem-fg-dim);">
              {length(@broadcast_log)} / 50
            </span>
          </div>
          <div style="max-height: 320px; overflow-y: auto; padding: 8px 0;">
            <%= if @broadcast_log == [] do %>
              <div style="padding: 24px 16px; text-align: center; color: var(--ccem-fg-dim); font-size: 13px;">
                No messages yet. Waiting for A2A activity.
              </div>
            <% else %>
              <%= for entry <- @broadcast_log do %>
                <div style="display: flex; align-items: flex-start; gap: 8px; padding: 6px 16px; border-bottom: 1px solid var(--ccem-line);">
                  <.badge tone={entry.tone}>{entry.type}</.badge>
                  <div style="flex: 1; min-width: 0;">
                    <div style="font-family: var(--ccem-font-mono, monospace); font-size: 11px; color: var(--ccem-fg-dim); margin-bottom: 2px;">
                      {entry.id}
                    </div>
                    <div style="font-size: 12px; color: var(--ccem-fg); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                      {entry.preview}
                    </div>
                  </div>
                  <span style="font-size: 10px; color: var(--ccem-fg-muted); flex-shrink: 0;">
                    {entry.ts}
                  </span>
                </div>
              <% end %>
            <% end %>
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
            <div style="display: flex; flex-direction: column; gap: 12px;">
              <div>
                <div style="font-size: 13px; font-weight: 600; color: var(--ccem-fg); margin-bottom: 8px;">
                  Routing Stats
                </div>
                <div style="display: flex; flex-direction: column; gap: 8px;">
                  <.inspector_kv label="Sent" value={to_string(@stats[:sent_count] || 0)} mono />
                  <.inspector_kv label="Delivered" value={to_string(@stats[:delivered_count] || 0)} mono />
                  <.inspector_kv label="Expired" value={to_string(@stats[:expired_count] || 0)} mono />
                  <.inspector_kv label="Active Queues" value={to_string(map_size(@stats[:queue_depths] || %{}))} mono />
                </div>
              </div>

              <div>
                <div style="font-size: 11px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--ccem-fg-dim); margin-bottom: 6px;">
                  Recent Messages
                </div>
                <div style="font-size: 12px; color: var(--ccem-fg-dim);">
                  {length(@broadcast_log)} messages in feed.
                </div>
              </div>
            </div>
          </:selection>

          <:copilot>
            <p style="font-size: 13px; color: var(--ccem-fg-dim); margin: 0;">
              A2A co-pilot coming soon.
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

  @spec safe_stats() :: map()
  defp safe_stats do
    try do
      Router.stats()
    rescue
      _ -> %{sent_count: 0, delivered_count: 0, expired_count: 0, queue_depths: %{}}
    end
  end

  @spec build_routes(map()) :: [map()]
  defp build_routes(_stats), do: []

  @spec build_queue_pairs(map()) :: [map()]
  defp build_queue_pairs(stats) do
    (stats[:queue_depths] || %{})
    |> Enum.map(fn {agent_id, depth} ->
      %{agent_id: to_string(agent_id), depth: depth}
    end)
    |> Enum.sort_by(& &1.depth, :desc)
  end

  @spec build_graph_nodes(map()) :: [map()]
  defp build_graph_nodes(stats) do
    queues = stats[:queue_depths] || %{}

    if map_size(queues) == 0 do
      []
    else
      # Synthesize a "router" hub node plus one node per agent with a queue.
      hub = %{id: "router", label: "Router", role: "orchestrator", status: "active"}

      agents =
        queues
        |> Enum.map(fn {agent_id, _depth} ->
          %{id: to_string(agent_id), label: truncate(to_string(agent_id), 12), role: "individual", status: "active"}
        end)

      [hub | agents]
    end
  end

  @spec build_graph_edges(map()) :: [map()]
  defp build_graph_edges(stats) do
    queues = stats[:queue_depths] || %{}

    Enum.map(queues, fn {agent_id, _depth} ->
      %{
        id: "router-#{agent_id}",
        source_id: "router",
        target_id: to_string(agent_id),
        edge_type: "default",
        live: true
      }
    end)
  end

  @spec build_log_entry(map()) :: map()
  defp build_log_entry(event) do
    type = to_string(event[:name] || event[:type] || "a2a")
    value = event[:value] || event

    id =
      case value do
        m when is_map(m) -> truncate(to_string(Map.get(m, :id, "")), 8)
        _ -> "—"
      end

    preview =
      case Jason.encode(value) do
        {:ok, json} -> truncate(json, 80)
        _ -> inspect(value) |> truncate(80)
      end

    tone =
      cond do
        String.contains?(type, "error") -> "error"
        String.contains?(type, "deliver") -> "success"
        String.contains?(type, "expire") -> "warning"
        true -> "iris"
      end

    %{
      type: type,
      id: id,
      preview: preview,
      tone: tone,
      ts: time_now()
    }
  end

  @spec time_now() :: String.t()
  defp time_now do
    DateTime.utc_now() |> Calendar.strftime("%H:%M:%S")
  end

  @spec truncate(String.t(), integer()) :: String.t()
  defp truncate(s, max) when byte_size(s) > max, do: String.slice(s, 0, max) <> "…"
  defp truncate(s, _max), do: s

end
