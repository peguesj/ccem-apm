defmodule ApmV5Web.ArchitectureLive do
  @moduledoc """
  Observe — Architecture LiveView (CP-182 / US-457).

  OTP system architecture visualization using the CCEM design system shell.

  ## Layout
  - Supervision tree: `<svg phx-hook="GraphForce">` with `graph_node`/`graph_edge`
    elements showing the registered architecture hierarchy
  - GenServer list: `data_table` — Name / Module / Status / Memory / Messages
  - ETS tables: card list with table name and size
  - PubSub topics: `data_table` — Topic / Subscribers / Messages/min

  ## Data
  Reads from `ApmV5.Architectures.ArchitectureStore` and `ApmV5.AgentRegistry`.
  No PubSub subscription (static architecture data). Refreshes every 10 seconds.
  """

  use ApmV5Web, :live_view

  alias ApmV5.Architectures.ArchitectureStore
  alias ApmV5.AgentRegistry

  @refresh_ms 10_000

  # ---------------------------------------------------------------------------
  # mount/3
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:architectures")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:agents")
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    {architectures, active_arch, tree, graph_config} = load_architecture_data(nil)
    {genservers, ets_tables, pubsub_topics} = load_system_data()

    {:ok,
     socket
     |> assign(
       page_title: "Architecture",
       sidebar_collapsed: false,
       inspector_open: false,
       inspector_mode: "selection",
       view_mode: "graph",
       architectures: architectures,
       active_architecture: active_arch,
       tree: tree,
       graph_config: graph_config,
       genservers: genservers,
       ets_tables: ets_tables,
       pubsub_topics: pubsub_topics
     )
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  # ---------------------------------------------------------------------------
  # handle_info/2
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {_archs, _active, tree, graph_config} = load_architecture_data(socket.assigns.active_architecture)
    {genservers, ets_tables, pubsub_topics} = load_system_data()

    socket =
      socket
      |> assign(tree: tree, graph_config: graph_config, genservers: genservers, ets_tables: ets_tables, pubsub_topics: pubsub_topics)
      |> maybe_push_graph(tree, graph_config)

    {:noreply, socket}
  end

  def handle_info({:tree_built, _name, _tree}, socket) do
    {_archs, _active, tree, graph_config} = load_architecture_data(socket.assigns.active_architecture)

    {:noreply,
     socket
     |> assign(tree: tree, graph_config: graph_config)
     |> maybe_push_graph(tree, graph_config)}
  end

  def handle_info({:agent_registered, _}, socket) do
    {_archs, _active, tree, graph_config} = load_architecture_data(socket.assigns.active_architecture)

    {:noreply,
     socket
     |> assign(tree: tree, graph_config: graph_config)
     |> maybe_push_graph(tree, graph_config)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # handle_event/3
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("switch_architecture", %{"name" => name}, socket) do
    {_archs, active, tree, graph_config} = load_architecture_data(name)

    {:noreply,
     socket
     |> assign(active_architecture: active, tree: tree, graph_config: graph_config)
     |> maybe_push_graph(tree, graph_config)}
  end

  @impl true
  def handle_event("switch_view", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, view_mode: mode)}
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
    assigns = assign(assigns, graph_nodes: build_graph_nodes(assigns.tree), graph_edges: build_graph_edges(assigns.tree))

    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav current_path="/architecture" />
      </:sidebar>

      <:topbar>
        <.top_bar project_name="CCEM APM" />
      </:topbar>

      <:main>
        <%!-- Page header --%>
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
          <div style="display: flex; align-items: baseline; gap: 10px;">
            <h1 style="margin: 0; font-size: 16px; font-weight: 600; color: var(--ccem-fg);">
              Architecture
            </h1>
            <%= if @tree do %>
              <span style="font-size: 12px; color: var(--ccem-fg-dim);">
                {@tree["agent_count"] || 0} agents
              </span>
            <% end %>
          </div>
          <div style="display: flex; align-items: center; gap: 8px;">
            <.segmented_control
              options={["graph", "list"]}
              active={@view_mode}
              on_change="switch_view"
            />
            <button
              phx-click="toggle_inspector"
              style="display: flex; align-items: center; justify-content: center; width: 28px; height: 28px; background: var(--ccem-bg-2); border: 1px solid var(--ccem-line); border-radius: 5px; cursor: pointer; color: var(--ccem-fg-dim); font-size: 13px;"
              title="Toggle inspector"
            >
              &#9776;
            </button>
          </div>
        </div>

        <%!-- Architecture selector --%>
        <%= if length(@architectures) > 1 do %>
          <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 16px; flex-wrap: wrap;">
            <span style="font-size: 11px; color: var(--ccem-fg-dim); font-weight: 500;">Architecture:</span>
            <%= for arch <- @architectures do %>
              <button
                phx-click="switch_architecture"
                phx-value-name={arch.name}
                style={
                  "padding: 3px 10px; font-size: 11px; font-weight: 500; border-radius: 999px; cursor: pointer; border: 1px solid; transition: background 120ms; " <>
                    if(@active_architecture == arch.name,
                      do: "background: var(--ccem-bg-3); color: var(--ccem-fg); border-color: var(--ccem-line);",
                      else: "background: transparent; color: var(--ccem-fg-dim); border-color: transparent;"
                    )
                }
              >
                {arch.name}
              </button>
            <% end %>
          </div>
        <% end %>

        <%!-- Supervision tree graph --%>
        <%= if @view_mode == "graph" do %>
          <.card padded={false} style="margin-bottom: 16px; overflow: hidden;">
            <div style="padding: 12px 16px 8px; border-bottom: 1px solid var(--ccem-line);">
              <span style="font-size: 13px; font-weight: 600; color: var(--ccem-fg);">
                Supervision Tree
              </span>
            </div>
            <svg
              id="architecture-graph"
              phx-hook="GraphForce"
              phx-update="ignore"
              width="100%"
              height="320"
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
            <%= if @graph_nodes == [] do %>
              <div style="padding: 32px 16px; text-align: center; color: var(--ccem-fg-dim); font-size: 13px;">
                No architecture data. Register agents to build the supervision tree.
              </div>
            <% end %>
          </.card>
        <% else %>
          <%!-- List view: recursive tree --%>
          <.card style="margin-bottom: 16px;">
            <span style="font-size: 13px; font-weight: 600; color: var(--ccem-fg);">Supervision Tree</span>
            <%= if @tree do %>
              <div style="margin-top: 12px;">
                <.tree_node_view node={@tree} depth={0} />
              </div>
            <% else %>
              <div style="margin-top: 12px; color: var(--ccem-fg-dim); font-size: 13px;">
                No architecture data yet.
              </div>
            <% end %>
          </.card>
        <% end %>

        <%!-- GenServer list --%>
        <.card padded={false} style="margin-bottom: 16px;">
          <div style="padding: 12px 16px 8px; border-bottom: 1px solid var(--ccem-line);">
            <span style="font-size: 13px; font-weight: 600; color: var(--ccem-fg);">
              GenServers
            </span>
          </div>
          <.data_table id="genserver-table" rows={@genservers}>
            <:col :let={gs} label="Name">
              <span style="font-family: var(--ccem-font-mono, monospace); font-size: 11px; color: var(--ccem-fg);">
                {gs.name}
              </span>
            </:col>
            <:col :let={gs} label="Module">
              <span style="font-family: var(--ccem-font-mono, monospace); font-size: 10px; color: var(--ccem-fg-dim);">
                {gs.module}
              </span>
            </:col>
            <:col :let={gs} label="Status">
              <.badge tone={gs_status_tone(gs.status)}>{gs.status}</.badge>
            </:col>
            <:col :let={gs} label="Memory">
              <span style="font-family: var(--ccem-font-mono, monospace); font-size: 12px; font-variant-numeric: tabular-nums; color: var(--ccem-fg);">
                {format_bytes(gs.memory)}
              </span>
            </:col>
            <:col :let={gs} label="Messages">
              <span style="font-family: var(--ccem-font-mono, monospace); font-size: 12px; font-variant-numeric: tabular-nums; color: var(--ccem-fg);">
                {gs.message_queue_len}
              </span>
            </:col>
          </.data_table>

          <%= if @genservers == [] do %>
            <div style="padding: 24px 16px; text-align: center; color: var(--ccem-fg-dim); font-size: 13px;">
              No registered GenServers found.
            </div>
          <% end %>
        </.card>

        <%!-- ETS Tables --%>
        <div style="margin-bottom: 16px;">
          <div style="font-size: 11px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--ccem-fg-dim); margin-bottom: 8px;">
            ETS Tables
          </div>
          <%= if @ets_tables == [] do %>
            <.card>
              <span style="font-size: 13px; color: var(--ccem-fg-dim);">No ETS tables visible.</span>
            </.card>
          <% else %>
            <div style="display: flex; flex-wrap: wrap; gap: 8px;">
              <%= for tbl <- @ets_tables do %>
                <.card style="flex: 0 0 auto; padding: 8px 14px; min-width: 140px;">
                  <div style="font-family: var(--ccem-font-mono, monospace); font-size: 11px; color: var(--ccem-fg); margin-bottom: 4px; word-break: break-all;">
                    {tbl.name}
                  </div>
                  <div style="display: flex; align-items: center; gap: 6px;">
                    <.badge tone="neutral">{format_bytes(tbl.memory)}</.badge>
                    <span style="font-size: 10px; color: var(--ccem-fg-dim);">{tbl.size} rows</span>
                  </div>
                </.card>
              <% end %>
            </div>
          <% end %>
        </div>

        <%!-- PubSub topics --%>
        <.card padded={false}>
          <div style="padding: 12px 16px 8px; border-bottom: 1px solid var(--ccem-line);">
            <span style="font-size: 13px; font-weight: 600; color: var(--ccem-fg);">PubSub Topics</span>
          </div>
          <.data_table id="pubsub-table" rows={@pubsub_topics}>
            <:col :let={topic} label="Topic">
              <span style="font-family: var(--ccem-font-mono, monospace); font-size: 11px; color: var(--ccem-fg);">
                {topic.name}
              </span>
            </:col>
            <:col :let={topic} label="Subscribers">
              <span style="font-family: var(--ccem-font-mono, monospace); font-size: 12px; font-variant-numeric: tabular-nums; color: var(--ccem-fg);">
                {topic.subscriber_count}
              </span>
            </:col>
            <:col :let={topic} label="Status">
              <.badge tone={if topic.subscriber_count > 0, do: "success", else: "neutral"}>
                {if topic.subscriber_count > 0, do: "Active", else: "Idle"}
              </.badge>
            </:col>
          </.data_table>

          <%= if @pubsub_topics == [] do %>
            <div style="padding: 24px 16px; text-align: center; color: var(--ccem-fg-dim); font-size: 13px;">
              No PubSub topics observed.
            </div>
          <% end %>
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
              <div style="font-size: 13px; font-weight: 600; color: var(--ccem-fg);">
                System Overview
              </div>
              <div style="display: flex; flex-direction: column; gap: 8px;">
                <.inspector_kv label="Architecture" value={@active_architecture || "—"} />
                <.inspector_kv label="GenServers" value={to_string(length(@genservers))} mono />
                <.inspector_kv label="ETS Tables" value={to_string(length(@ets_tables))} mono />
                <.inspector_kv label="PubSub Topics" value={to_string(length(@pubsub_topics))} mono />
                <%= if @tree do %>
                  <.inspector_kv label="Agent Count" value={to_string(@tree["agent_count"] || 0)} mono />
                <% end %>
              </div>
            </div>
          </:selection>

          <:copilot>
            <p style="font-size: 13px; color: var(--ccem-fg-dim); margin: 0;">
              Architecture co-pilot coming soon.
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

  attr :node, :map, required: true
  attr :depth, :integer, required: true

  defp tree_node_view(assigns) do
    ~H"""
    <div style={"margin-left: #{min(@depth * 16, 64)}px; border-left: 1px solid var(--ccem-line); padding-left: 12px; padding-top: 4px;"}>
      <div style="display: flex; align-items: center; gap: 8px; padding: 4px 6px; border-radius: 4px;">
        <span style={"width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; background: #{level_color(@node["level"])};"} />
        <span style="font-family: var(--ccem-font-mono, monospace); font-size: 10px; color: var(--ccem-fg-dim);">
          {@node["level"]}
        </span>
        <span style="font-size: 13px; font-weight: 500; color: var(--ccem-fg);">
          {@node["name"]}
        </span>
        <%= if (@node["agent_count"] || 0) > 0 do %>
          <.badge tone="neutral">{@node["agent_count"]} agents</.badge>
        <% end %>
      </div>
      <%= for child <- @node["children"] || [] do %>
        <.tree_node_view node={child} depth={@depth + 1} />
      <% end %>
    </div>
    """
  end

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
  # Private helpers — data loading
  # ---------------------------------------------------------------------------

  @spec load_architecture_data(String.t() | nil) ::
          {[map()], String.t() | nil, map() | nil, map() | nil}
  defp load_architecture_data(preferred_arch) do
    architectures =
      try do
        ArchitectureStore.list_architectures()
      rescue
        _ -> []
      end

    active_arch =
      preferred_arch || (List.first(architectures) && List.first(architectures).name) || "diligent"

    agents =
      try do
        AgentRegistry.list_agents()
      rescue
        _ -> []
      end

    {tree, graph_config} =
      try do
        case ArchitectureStore.build_tree(active_arch, agents) do
          {:ok, t} -> {t, ArchitectureStore.graph_config(active_arch)}
          _ -> {nil, nil}
        end
      rescue
        _ -> {nil, nil}
      end

    {architectures, active_arch, tree, graph_config}
  end

  @spec load_system_data() :: {[map()], [map()], [map()]}
  defp load_system_data do
    genservers = load_genservers()
    ets_tables = load_ets_tables()
    pubsub_topics = load_pubsub_topics()
    {genservers, ets_tables, pubsub_topics}
  end

  @spec load_genservers() :: [map()]
  defp load_genservers do
    try do
      # Collect named processes that are GenServers.
      :erlang.registered()
      |> Enum.filter(fn name ->
        case Process.whereis(name) do
          pid when is_pid(pid) ->
            case Process.info(pid, [:dictionary]) do
              [{:dictionary, dict}] -> Keyword.get(dict, :"$initial_call") != nil
              _ -> false
            end
          _ -> false
        end
      end)
      |> Enum.map(fn name ->
        pid = Process.whereis(name)
        info = Process.info(pid, [:memory, :message_queue_len, :dictionary]) || []
        dict = Keyword.get(info, :dictionary, [])
        initial_call = Keyword.get(dict, :"$initial_call", {name, :init, 1})

        module =
          case initial_call do
            {mod, _fun, _arity} -> inspect(mod)
            _ -> inspect(name)
          end

        %{
          name: inspect(name),
          module: module,
          status: "running",
          memory: Keyword.get(info, :memory, 0),
          message_queue_len: Keyword.get(info, :message_queue_len, 0)
        }
      end)
      |> Enum.sort_by(& &1.name)
      |> Enum.take(50)
    rescue
      _ -> []
    end
  end

  @spec load_ets_tables() :: [map()]
  defp load_ets_tables do
    try do
      :ets.all()
      |> Enum.map(fn table ->
        info = :ets.info(table) || []
        name = Keyword.get(info, :name, table)
        memory_words = Keyword.get(info, :memory, 0)
        size = Keyword.get(info, :size, 0)

        %{
          name: inspect(name),
          memory: memory_words * :erlang.system_info(:wordsize),
          size: size
        }
      end)
      |> Enum.sort_by(& &1.memory, :desc)
      |> Enum.take(30)
    rescue
      _ -> []
    end
  end

  @spec load_pubsub_topics() :: [map()]
  defp load_pubsub_topics do
    # Known APM PubSub topics — enumerate statically as Phoenix.PubSub
    # does not expose a topic list API.
    known_topics = [
      "apm:agents",
      "apm:tool_calls",
      "apm:a2a",
      "apm:conversations",
      "apm:architectures",
      "apm:notifications",
      "apm:formation",
      "dashboard:scope"
    ]

    Enum.map(known_topics, fn topic ->
      subscriber_count =
        try do
          Phoenix.PubSub.node_name(ApmV5.PubSub)
          # Phoenix.PubSub has no public subscriber count API; use 0 as sentinel.
          0
        rescue
          _ -> 0
        end

      %{name: topic, subscriber_count: subscriber_count}
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers — graph building
  # ---------------------------------------------------------------------------

  @spec build_graph_nodes(map() | nil) :: [map()]
  defp build_graph_nodes(nil), do: []

  defp build_graph_nodes(tree) do
    flatten_tree_nodes(tree, [])
  end

  @spec flatten_tree_nodes(map(), [map()]) :: [map()]
  defp flatten_tree_nodes(node, acc) do
    entry = %{
      id: node["name"] || "root",
      label: truncate(node["name"] || "root", 14),
      role: level_role(node["level"]),
      status: node["status"] || "idle"
    }

    children_acc =
      (node["children"] || [])
      |> Enum.reduce(acc, fn child, a -> flatten_tree_nodes(child, a) end)

    [entry | children_acc]
  end

  @spec build_graph_edges(map() | nil) :: [map()]
  defp build_graph_edges(nil), do: []

  defp build_graph_edges(tree) do
    flatten_tree_edges(tree, [])
  end

  @spec flatten_tree_edges(map(), [map()]) :: [map()]
  defp flatten_tree_edges(node, acc) do
    parent_id = node["name"] || "root"

    children_edges =
      (node["children"] || [])
      |> Enum.flat_map(fn child ->
        child_id = child["name"] || "node"

        edge = %{
          id: "#{parent_id}-#{child_id}",
          source_id: parent_id,
          target_id: child_id,
          edge_type: "supervision",
          live: false
        }

        [edge | flatten_tree_edges(child, [])]
      end)

    acc ++ children_edges
  end

  @spec maybe_push_graph(Phoenix.LiveView.Socket.t(), map() | nil, map() | nil) ::
          Phoenix.LiveView.Socket.t()
  defp maybe_push_graph(socket, nil, _graph_config), do: socket

  defp maybe_push_graph(socket, tree, graph_config) do
    push_event(socket, "architecture:data", %{tree: tree, config: graph_config})
  end

  # ---------------------------------------------------------------------------
  # Private helpers — formatting
  # ---------------------------------------------------------------------------

  @spec format_bytes(integer() | nil) :: String.t()
  defp format_bytes(nil), do: "—"
  defp format_bytes(b) when b >= 1_048_576, do: "#{Float.round(b / 1_048_576, 1)} MB"
  defp format_bytes(b) when b >= 1_024, do: "#{Float.round(b / 1_024, 1)} KB"
  defp format_bytes(b) when is_integer(b), do: "#{b} B"
  defp format_bytes(_), do: "—"

  @spec gs_status_tone(String.t()) :: String.t()
  defp gs_status_tone("running"), do: "success"
  defp gs_status_tone("error"), do: "error"
  defp gs_status_tone(_), do: "neutral"

  @spec level_role(String.t() | nil) :: String.t()
  defp level_role("fleet"), do: "orchestrator"
  defp level_role("formation"), do: "orchestrator"
  defp level_role("squadron"), do: "swarm_agent"
  defp level_role(_), do: "individual"

  @spec level_color(String.t() | nil) :: String.t()
  defp level_color("fleet"), do: "#c084fc"
  defp level_color("formation"), do: "#60a5fa"
  defp level_color("squadron"), do: "#22d3ee"
  defp level_color("swarm"), do: "#4ade80"
  defp level_color("agent"), do: "#fb923c"
  defp level_color(_), do: "#6b7280"

  @spec truncate(String.t(), integer()) :: String.t()
  defp truncate(s, max) when byte_size(s) > max, do: String.slice(s, 0, max) <> "…"
  defp truncate(s, _max), do: s
end
