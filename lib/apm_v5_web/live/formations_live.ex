defmodule ApmV5Web.FormationsLive do
  @moduledoc """
  Observe — Formations LiveView (CP-179 / US-454).

  Redesigned formations view using the CCEM design system components. Renders
  four layout modes for the same underlying formation/agent data:

  - **Tree**   — D3 force-directed graph via `phx-hook="FormationGraph"` with
    `<.graph_node>` and `<.graph_edge>` SVG elements.
  - **Matrix** — CSS grid of `<.card>` / `<.stat_tile>` formation cards.
  - **List**   — Dense `<.data_table>` with formation metadata columns.
  - **Dot**    — Minimal status dots via `<.badge dot={true}>` spans.

  ## Real-time
  Subscribes to `"apm:formations"`, `"apm:agents"`, and `"apm:upm"` PubSub
  topics, and receives `AG-UI` EventBus `"lifecycle:*"` events.

  ## Route
  `GET /observe/formation` → `FormationsLive, :index`
  """

  use ApmV5Web, :live_view

  alias ApmV5.AgentRegistry
  alias ApmV5.UpmStore

  @pubsub_topic_formations "apm:formations"
  @pubsub_topic_agents "apm:agents"
  @pubsub_topic_upm "apm:upm"
  @refresh_ms 10_000

  # Layout modes surfaced in the segmented control
  @layout_modes ["Tree", "Matrix", "List", "Dot"]

  # ---------------------------------------------------------------------------
  # mount/3
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic_formations)
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic_agents)
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic_upm)
      ApmV5.AgUi.EventBus.subscribe("lifecycle:*")
      Process.send_after(self(), :refresh, @refresh_ms)
      # Defer the initial push_event until after the JS hook is mounted (150ms grace)
      Process.send_after(self(), :push_graph, 150)
    end

    {formations, graph_nodes, graph_edges} = load_formations()

    {:ok,
     socket
     |> assign(
       page_title: "Formations",
       layout_mode: "Tree",
       scope: "all",
       sidebar_collapsed: false,
       inspector_open: false,
       inspector_mode: "selection",
       selected_formation: nil,
       formations: formations,
       graph_nodes: graph_nodes,
       graph_edges: graph_edges
     )
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  # ---------------------------------------------------------------------------
  # handle_params/3
  # ---------------------------------------------------------------------------

  @impl true
  def handle_params(params, _uri, socket) do
    scope = params["scope"] || "all"
    {formations, graph_nodes, graph_edges} = load_formations(scope)

    {:noreply,
     socket
     |> assign(scope: scope, formations: formations, graph_nodes: graph_nodes, graph_edges: graph_edges)
     |> push_graph_data(graph_nodes, graph_edges)}
  end

  # ---------------------------------------------------------------------------
  # handle_info/2
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, reload_formations(socket)}
  end

  def handle_info({:agent_registered, _}, socket), do: {:noreply, reload_formations(socket)}
  def handle_info({:agent_updated, _}, socket), do: {:noreply, reload_formations(socket)}
  def handle_info({:upm_session_registered, _}, socket), do: {:noreply, reload_formations(socket)}
  def handle_info({:upm_agent_registered, _}, socket), do: {:noreply, reload_formations(socket)}
  def handle_info({:formation_registered, _}, socket), do: {:noreply, reload_formations(socket)}
  def handle_info({:formation_updated, _}, socket), do: {:noreply, reload_formations(socket)}

  def handle_info(:push_graph, socket) do
    {:noreply, push_graph_data(socket, socket.assigns.graph_nodes, socket.assigns.graph_edges)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # handle_event/3
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("switch_layout", %{"value" => mode}, socket) when mode in @layout_modes do
    socket = assign(socket, layout_mode: mode)

    socket =
      if mode == "Tree" do
        push_graph_data(socket, socket.assigns.graph_nodes, socket.assigns.graph_edges)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("switch_layout", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_formation", %{"id" => id}, socket) do
    formation = Enum.find(socket.assigns.formations, &(&1.id == id))

    {:noreply,
     assign(socket,
       selected_formation: formation,
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

  @impl true
  def handle_event("node_clicked", %{"id" => id, "level" => "formation"}, socket) do
    handle_event("select_formation", %{"id" => id}, socket)
  end

  def handle_event("node_clicked", _params, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # render/1
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        stat_formations: length(assigns.formations),
        stat_active: Enum.count(assigns.formations, &(formation_status(&1) == "active")),
        stat_agents: Enum.sum(Enum.map(assigns.formations, & &1.agent_count)),
        stat_waves: derive_total_waves(assigns.formations)
      )

    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav current_path="/observe/formation" />
      </:sidebar>

      <:topbar>
        <.top_bar project_name="CCEM APM" />
      </:topbar>

      <:main>
        <%!-- Page header row: title + layout switcher + inspector toggle --%>
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px; flex-wrap: wrap; gap: 8px;">
          <div style="display: flex; align-items: baseline; gap: 10px;">
            <h1 style="margin: 0; font-size: 16px; font-weight: 600; color: var(--ccem-fg);">
              Formations
            </h1>
            <span style="font-size: 12px; color: var(--ccem-fg-dim);">
              {@stat_formations} formation{if @stat_formations != 1, do: "s", else: ""}
            </span>
          </div>

          <div style="display: flex; align-items: center; gap: 10px; flex-wrap: wrap;">
            <.segmented_control
              options={["Tree", "Matrix", "List", "Dot"]}
              active={@layout_mode}
              on_change="switch_layout"
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

        <%!-- Stat tiles row --%>
        <div style="display: flex; gap: 12px; margin-bottom: 16px; flex-wrap: wrap;">
          <.card style="flex: 1; min-width: 110px; padding: 12px 16px;">
            <.stat_tile label="Formations" value={to_string(@stat_formations)} />
          </.card>
          <.card style="flex: 1; min-width: 110px; padding: 12px 16px;">
            <.stat_tile label="Active" value={to_string(@stat_active)} />
          </.card>
          <.card style="flex: 1; min-width: 110px; padding: 12px 16px;">
            <.stat_tile label="Agents" value={to_string(@stat_agents)} />
          </.card>
          <.card style="flex: 1; min-width: 110px; padding: 12px 16px;">
            <.stat_tile label="Waves" value={to_string(@stat_waves)} />
          </.card>
        </div>

        <%!-- Layout views --%>

        <%!-- ── Tree mode (D3 force graph) ────────────────────────────────── --%>
        <div :if={@layout_mode == "Tree"}>
          <%= if @formations == [] do %>
            <.empty_state_view />
          <% else %>
            <.card padded={false}>
              <div
                id="formations-force-graph"
                phx-hook="FormationGraph"
                phx-update="ignore"
                data-orientation="graph_td"
                style="width: 100%; height: 560px; display: block; background: var(--ccem-bg-0, #0d1117);"
              >
                <%!-- Formation nodes --%>
                <%= for node <- @graph_nodes do %>
                  <.graph_node
                    node_id={node.id}
                    label={node.name}
                    role={node[:role] || formation_level_role(node[:level])}
                    status={node[:status] || "idle"}
                  />
                <% end %>
                <%!-- Edges --%>
                <%= for edge <- @graph_edges do %>
                  <.graph_edge
                    edge_id={"e-#{edge.source}-#{edge.target}"}
                    source_id={edge.source}
                    target_id={edge.target}
                    edge_type={edge.edge_type || "default"}
                    live={edge[:live] || false}
                  />
                <% end %>
              </div>
            </.card>

            <%!-- Edge type legend --%>
            <div style="display: flex; align-items: center; gap: 16px; margin-top: 10px; flex-wrap: wrap;">
              <span style="font-size: 11px; color: var(--ccem-fg-dim); font-weight: 500; letter-spacing: 0.05em; text-transform: uppercase;">
                Edge types:
              </span>
              <.edge_legend_item color="var(--ccem-fg-dim)" dash="5,3" label="Hierarchy" />
              <.edge_legend_item color="var(--ccem-iris, #7c6cf8)" dash="4,3" label="Pub/Sub" />
              <.edge_legend_item color="var(--ccem-ok, #22c55e)" dash="8,4" label="Data Flow" />
              <.edge_legend_item color="var(--ccem-fg)" dash="" label="Export" />
            </div>
          <% end %>
        </div>

        <%!-- ── Matrix mode (grid of formation cards) ───────────────────── --%>
        <div :if={@layout_mode == "Matrix"}>
          <%= if @formations == [] do %>
            <.empty_state_view />
          <% else %>
            <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 12px;">
              <%= for formation <- @formations do %>
                <% fstatus = formation_status(formation) %>
                <button
                  phx-click="select_formation"
                  phx-value-id={formation.id}
                  style={
                    "text-align: left; background: none; border: none; padding: 0; cursor: pointer; " <>
                      if(@selected_formation && @selected_formation.id == formation.id,
                        do: "outline: 2px solid var(--ccem-accent); outline-offset: 2px; border-radius: 8px;",
                        else: ""
                      )
                  }
                >
                  <.card>
                    <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 10px;">
                      <span style="font-size: 13px; font-weight: 600; color: var(--ccem-fg); font-family: var(--ccem-font-mono); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 160px;">
                        {formation.name}
                      </span>
                      <.badge tone={status_tone(fstatus)} dot={fstatus == "active"}>
                        {fstatus}
                      </.badge>
                    </div>

                    <div style="display: flex; gap: 16px;">
                      <.stat_tile label="Agents" value={to_string(formation.agent_count)} />
                      <.stat_tile label="Squads" value={to_string(length(formation.squadrons))} />
                      <.stat_tile label="Waves" value={to_string(formation_wave_count(formation))} />
                    </div>

                    <div :if={formation[:source]} style="margin-top: 8px;">
                      <.badge tone="neutral">
                        {source_label(formation[:source])}
                      </.badge>
                    </div>
                  </.card>
                </button>
              <% end %>
            </div>
          <% end %>
        </div>

        <%!-- ── List mode (data_table) ──────────────────────────────────── --%>
        <div :if={@layout_mode == "List"}>
          <%= if @formations == [] do %>
            <.empty_state_view />
          <% else %>
            <.card padded={false}>
              <.data_table id="formations-list-table" rows={@formations}>
                <:col :let={f} label="Name">
                  <button
                    phx-click="select_formation"
                    phx-value-id={f.id}
                    style="background: none; border: none; padding: 0; cursor: pointer; font-family: var(--ccem-font-mono, monospace); font-size: 12px; color: var(--ccem-fg); text-align: left; max-width: 240px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; display: block;"
                  >
                    {f.name}
                  </button>
                </:col>
                <:col :let={f} label="Status">
                  <.badge tone={status_tone(formation_status(f))} dot={formation_status(f) == "active"}>
                    {formation_status(f)}
                  </.badge>
                </:col>
                <:col :let={f} label="Agents">
                  <span style="font-family: var(--ccem-font-mono); font-size: 12px; font-variant-numeric: tabular-nums; color: var(--ccem-fg);">
                    {f.agent_count}
                  </span>
                </:col>
                <:col :let={f} label="Squadrons">
                  <span style="font-family: var(--ccem-font-mono); font-size: 12px; font-variant-numeric: tabular-nums; color: var(--ccem-fg);">
                    {length(f.squadrons)}
                  </span>
                </:col>
                <:col :let={f} label="Waves">
                  <span style="font-family: var(--ccem-font-mono); font-size: 12px; font-variant-numeric: tabular-nums; color: var(--ccem-fg);">
                    {formation_wave_count(f)}
                  </span>
                </:col>
                <:col :let={f} label="Source">
                  <.badge tone="neutral">
                    {source_label(f[:source])}
                  </.badge>
                </:col>
                <:col :let={f} label="Registered">
                  <span style="font-size: 12px; color: var(--ccem-fg-muted);">
                    {format_registered_at(f)}
                  </span>
                </:col>
              </.data_table>
            </.card>
          <% end %>
        </div>

        <%!-- ── Dot mode (minimal status dots) ──────────────────────────── --%>
        <div :if={@layout_mode == "Dot"}>
          <%= if @formations == [] do %>
            <.empty_state_view />
          <% else %>
            <.card>
              <div style="display: flex; flex-wrap: wrap; gap: 12px;">
                <%= for formation <- @formations do %>
                  <% fstatus = formation_status(formation) %>
                  <button
                    phx-click="select_formation"
                    phx-value-id={formation.id}
                    style={
                      "display: flex; align-items: center; gap: 6px; background: none; border: none; cursor: pointer; padding: 4px 6px; border-radius: 5px; " <>
                        "background: var(--ccem-bg-2); " <>
                        if(@selected_formation && @selected_formation.id == formation.id,
                          do: "outline: 2px solid var(--ccem-accent); outline-offset: 1px;",
                          else: ""
                        )
                    }
                    title={formation.name}
                  >
                    <.badge tone={status_tone(fstatus)} dot={fstatus == "active"}>
                      {formation_short_name(formation.name)}
                    </.badge>
                    <span style="font-family: var(--ccem-font-mono); font-size: 10px; color: var(--ccem-fg-dim);">
                      {formation.agent_count}
                    </span>
                  </button>
                <% end %>
              </div>

              <%!-- Legend for dot colours --%>
              <div style="display: flex; align-items: center; gap: 12px; margin-top: 16px; padding-top: 12px; border-top: 1px solid var(--ccem-line-subtle); flex-wrap: wrap;">
                <span style="font-size: 11px; color: var(--ccem-fg-dim); font-weight: 500; text-transform: uppercase; letter-spacing: 0.06em;">Status:</span>
                <.badge tone="ok" dot={true}>active</.badge>
                <.badge tone="info">complete</.badge>
                <.badge tone="err">error</.badge>
                <.badge tone="neutral">idle</.badge>
              </div>
            </.card>
          <% end %>
        </div>
      </:main>

      <:inspector>
        <.inspector_panel
          open={@inspector_open}
          mode={@inspector_mode}
          on_close="toggle_inspector"
        >
          <:selection>
            <%= if @selected_formation do %>
              <% sel = @selected_formation %>
              <% fstatus = formation_status(sel) %>
              <div style="display: flex; flex-direction: column; gap: 14px;">
                <%!-- Identity --%>
                <div>
                  <div style="font-size: 13px; font-weight: 600; color: var(--ccem-fg); margin-bottom: 4px; word-break: break-all; font-family: var(--ccem-font-mono);">
                    {sel.name}
                  </div>
                  <.badge tone={status_tone(fstatus)} dot={fstatus == "active"}>
                    {fstatus}
                  </.badge>
                </div>

                <%!-- Key metrics --%>
                <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
                  <.stat_tile label="Agents" value={to_string(sel.agent_count)} />
                  <.stat_tile label="Squads" value={to_string(length(sel.squadrons))} />
                  <.stat_tile label="Waves" value={to_string(formation_wave_count(sel))} />
                  <.stat_tile label="Source" value={source_label(sel[:source])} />
                </div>

                <%!-- Registered at --%>
                <div :if={sel[:registered_at]} style="font-size: 11px; color: var(--ccem-fg-dim);">
                  Registered: {format_registered_at(sel)}
                </div>

                <%!-- Squadron breakdown --%>
                <div :if={sel.squadrons != []}>
                  <div style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-dim); margin-bottom: 8px;">
                    Squadrons
                  </div>
                  <div style="display: flex; flex-direction: column; gap: 4px;">
                    <%= for sq <- sel.squadrons do %>
                      <div style="display: flex; align-items: center; justify-content: space-between; padding: 4px 8px; background: var(--ccem-bg-2); border-radius: 5px; font-size: 12px;">
                        <span style="color: var(--ccem-fg); font-family: var(--ccem-font-mono); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 150px;">
                          {sq.name}
                        </span>
                        <.badge tone={status_tone(sq[:status] || "idle")}>
                          {sq[:status] || "idle"}
                        </.badge>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>
            <% else %>
              <div style="display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 32px 16px; color: var(--ccem-fg-dim); text-align: center;">
                <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" fill="none" viewBox="0 0 24 24" stroke="currentColor" style="opacity: 0.3; margin-bottom: 10px;">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M3.75 6A2.25 2.25 0 016 3.75h2.25A2.25 2.25 0 0110.5 6v2.25a2.25 2.25 0 01-2.25 2.25H6a2.25 2.25 0 01-2.25-2.25V6zM3.75 15.75A2.25 2.25 0 016 13.5h2.25a2.25 2.25 0 012.25 2.25V18a2.25 2.25 0 01-2.25 2.25H6A2.25 2.25 0 013.75 18v-2.25zM13.5 6a2.25 2.25 0 012.25-2.25H18A2.25 2.25 0 0120.25 6v2.25A2.25 2.25 0 0118 10.5h-2.25a2.25 2.25 0 01-2.25-2.25V6zM13.5 15.75a2.25 2.25 0 012.25-2.25H18a2.25 2.25 0 012.25 2.25V18A2.25 2.25 0 0118 20.25h-2.25A2.25 2.25 0 0113.5 18v-2.25z" />
                </svg>
                <p style="font-size: 13px; font-weight: 500; margin: 0 0 4px; color: var(--ccem-fg-muted);">
                  No selection
                </p>
                <p style="font-size: 11px; margin: 0; opacity: 0.6;">
                  Click a formation to inspect its details.
                </p>
              </div>
            <% end %>
          </:selection>
          <:filters>
            <div style="display: flex; flex-direction: column; gap: 10px;">
              <div style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-dim);">
                Scope
              </div>
              <div style="display: flex; flex-direction: column; gap: 4px;">
                <%= for scope_opt <- ["all", "live", "registered", "notifications"] do %>
                  <button
                    phx-click={JS.patch("/observe/formations?scope=#{scope_opt}")}
                    style={
                      "padding: 5px 10px; font-size: 12px; border-radius: 5px; cursor: pointer; text-align: left; " <>
                        "border: 1px solid; " <>
                        if(@scope == scope_opt,
                          do: "background: var(--ccem-iris-soft); border-color: var(--ccem-iris); color: var(--ccem-fg);",
                          else: "background: transparent; border-color: var(--ccem-line); color: var(--ccem-fg-dim);"
                        )
                    }
                  >
                    {String.capitalize(scope_opt)}
                  </button>
                <% end %>
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

  defp empty_state_view(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 64px 16px; color: var(--ccem-fg-dim);">
      <svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" fill="none" viewBox="0 0 24 24" stroke="currentColor" style="opacity: 0.25; margin-bottom: 16px;">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M3.75 6A2.25 2.25 0 016 3.75h2.25A2.25 2.25 0 0110.5 6v2.25a2.25 2.25 0 01-2.25 2.25H6a2.25 2.25 0 01-2.25-2.25V6zM3.75 15.75A2.25 2.25 0 016 13.5h2.25a2.25 2.25 0 012.25 2.25V18a2.25 2.25 0 01-2.25 2.25H6A2.25 2.25 0 013.75 18v-2.25zM13.5 6a2.25 2.25 0 012.25-2.25H18A2.25 2.25 0 0120.25 6v2.25A2.25 2.25 0 0118 10.5h-2.25a2.25 2.25 0 01-2.25-2.25V6zM13.5 15.75a2.25 2.25 0 012.25-2.25H18a2.25 2.25 0 012.25 2.25V18A2.25 2.25 0 0118 20.25h-2.25A2.25 2.25 0 0113.5 18v-2.25z" />
      </svg>
      <p style="font-size: 15px; font-weight: 600; margin: 0 0 6px; color: var(--ccem-fg-muted);">
        No Formations Active
      </p>
      <p style="font-size: 12px; margin: 0; text-align: center; max-width: 320px; line-height: 1.6; opacity: 0.65;">
        Formations appear when agents register with a <code style="font-family: var(--ccem-font-mono);">formation_id</code>.
        Use <code style="font-family: var(--ccem-font-mono);">/formation deploy</code> or POST to
        <code style="font-family: var(--ccem-font-mono);">/api/register</code>.
      </p>
    </div>
    """
  end

  attr :color, :string, required: true
  attr :dash, :string, default: ""
  attr :label, :string, required: true

  defp edge_legend_item(assigns) do
    ~H"""
    <div style="display: flex; align-items: center; gap: 6px;">
      <svg width="28" height="8" style="flex-shrink: 0;">
        <line
          x1="0" y1="4" x2="28" y2="4"
          stroke={@color}
          stroke-width="1.5"
          stroke-dasharray={@dash}
        />
      </svg>
      <span style="font-size: 11px; color: var(--ccem-fg-dim);">{@label}</span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Data loading
  # ---------------------------------------------------------------------------

  @spec load_formations() :: {list(), list(), list()}
  defp load_formations, do: load_formations("all")

  @spec load_formations(String.t() | nil) :: {list(), list(), list()}
  defp load_formations(scope) do
    agents = AgentRegistry.list_agents()
    upm_formations = try do UpmStore.list_formations() catch :exit, _ -> [] end
    all_formations = build_formation_tree(agents, upm_formations)

    formations =
      case scope do
        "live" -> Enum.filter(all_formations, &(&1[:source] == :live))
        "registered" -> Enum.filter(all_formations, &(&1[:source] == :upm))
        "notifications" -> Enum.filter(all_formations, &(&1[:source] == :notifications))
        _ -> all_formations
      end

    {graph_nodes, graph_edges} = build_graph_data(formations, agents)
    {formations, graph_nodes, graph_edges}
  end

  defp reload_formations(socket) do
    {formations, graph_nodes, graph_edges} = load_formations(socket.assigns.scope)

    socket
    |> assign(formations: formations, graph_nodes: graph_nodes, graph_edges: graph_edges)
    |> push_graph_data(graph_nodes, graph_edges)
  end

  # Push formation_data event for the FormationGraph JS hook (same payload as FormationLive).
  defp push_graph_data(socket, nodes, edges) do
    push_event(socket, "formation_data", %{nodes: nodes, edges: edges})
  end

  # ---------------------------------------------------------------------------
  # Graph data builder
  # ---------------------------------------------------------------------------

  @spec build_graph_data(list(), list()) :: {list(), list()}
  defp build_graph_data(formations, all_agents) do
    {nodes, edges} =
      Enum.reduce(formations, {[], []}, fn formation, {n, e} ->
        fstatus = formation_status(formation)

        formation_node = %{
          id: formation.id,
          name: formation.name,
          level: "formation",
          status: fstatus,
          count: formation.agent_count
        }

        n = [formation_node | n]

        Enum.reduce(formation.squadrons, {n, e}, fn squadron, {n2, e2} ->
          sq_id = "#{formation.id}/#{squadron.name}"

          sq_node = %{
            id: sq_id,
            name: squadron.name,
            level: "squadron",
            status: squadron[:status] || "idle",
            count: squadron_total_count(squadron)
          }

          e2 = [%{source: formation.id, target: sq_id, edge_type: "hierarchy"} | e2]
          n2 = [sq_node | n2]

          # Direct squadron agents
          {n2, e2} =
            Enum.reduce(squadron.agents, {n2, e2}, fn agent, {n3, e3} ->
              {[agent_to_node(agent) | n3],
               [%{source: sq_id, target: agent.id, edge_type: "hierarchy"} | e3]}
            end)

          # Swarms
          Enum.reduce(Map.get(squadron, :swarms, []), {n2, e2}, fn swarm, {n3, e3} ->
            sw_id = "#{sq_id}/#{swarm.name}"

            sw_node = %{
              id: sw_id,
              name: swarm.name,
              level: "swarm",
              status: swarm[:status] || "idle",
              count: swarm_total_count(swarm)
            }

            e3 = [%{source: sq_id, target: sw_id, edge_type: "hierarchy"} | e3]
            n3 = [sw_node | n3]

            {n3, e3} =
              Enum.reduce(Map.get(swarm, :agents, []), {n3, e3}, fn agent, {n4, e4} ->
                {[agent_to_node(agent) | n4],
                 [%{source: sw_id, target: agent.id, edge_type: "hierarchy"} | e4]}
              end)

            Enum.reduce(Map.get(swarm, :clusters, []), {n3, e3}, fn cluster, {n4, e4} ->
              cl_id = "#{sw_id}/#{cluster.name}"

              cl_node = %{
                id: cl_id,
                name: cluster.name,
                level: "cluster",
                status: cluster[:status] || "idle",
                count: length(cluster.agents)
              }

              e4 = [%{source: sw_id, target: cl_id, edge_type: "hierarchy"} | e4]
              n4 = [cl_node | n4]

              Enum.reduce(cluster.agents, {n4, e4}, fn agent, {n5, e5} ->
                {[agent_to_node(agent) | n5],
                 [%{source: cl_id, target: agent.id, edge_type: "hierarchy"} | e5]}
              end)
            end)
          end)
        end)
      end)

    # Pub/sub edges from agent metadata
    publisher_map =
      nodes
      |> Enum.filter(&(&1[:level] == "agent"))
      |> Enum.flat_map(fn node ->
        raw = Enum.find(all_agents, fn a -> a.id == node.id end)
        pubs = (raw && get_in(raw, [:metadata, :publishes])) || []
        Enum.map(pubs, fn ch -> {ch, node.id} end)
      end)
      |> Map.new()

    pubsub_edges =
      nodes
      |> Enum.filter(&(&1[:level] in ["agent", "squadron"]))
      |> Enum.flat_map(fn node ->
        raw = Enum.find(all_agents, fn a -> a.id == node.id end)
        subs = (raw && get_in(raw, [:metadata, :subscribes])) || []

        Enum.flat_map(subs, fn ch ->
          case Map.get(publisher_map, ch) do
            nil -> []
            pub_id -> [%{source: pub_id, target: node.id, edge_type: "pubsub", live: true}]
          end
        end)
      end)

    all_edges = edges ++ pubsub_edges

    {Enum.reverse(nodes), Enum.reverse(all_edges)}
  end

  # ---------------------------------------------------------------------------
  # Formation tree builder (delegated from FormationLive private logic)
  # ---------------------------------------------------------------------------

  defp build_formation_tree(agents, upm_formations) do
    formation_groups =
      agents
      |> Enum.filter(fn a ->
        fid = a[:formation_id]
        fid != nil and fid != ""
      end)
      |> Enum.group_by(& &1[:formation_id])

    live_formations =
      Enum.map(formation_groups, fn {formation_id, formation_agents} ->
        squadron_groups = Enum.group_by(formation_agents, &(&1[:squadron] || "default"))

        squadrons =
          Enum.map(squadron_groups, fn {squadron_name, sq_agents} ->
            {direct_agents, swarm_map} =
              sq_agents
              |> Enum.group_by(& &1[:swarm])
              |> Map.pop(nil, [])

            swarms =
              Enum.map(swarm_map, fn {swarm_name, sw_agents} ->
                {direct_sw, cluster_map} =
                  sw_agents
                  |> Enum.group_by(& &1[:cluster])
                  |> Map.pop(nil, [])

                clusters =
                  Enum.map(cluster_map, fn {cluster_name, cl_agents} ->
                    %{
                      name: cluster_name,
                      status: derive_status(cl_agents),
                      agents: Enum.map(cl_agents, &format_agent/1)
                    }
                  end)
                  |> Enum.sort_by(& &1.name)

                %{
                  name: swarm_name,
                  status: derive_status(sw_agents),
                  clusters: clusters,
                  agents: Enum.map(direct_sw, &format_agent/1)
                }
              end)
              |> Enum.sort_by(& &1.name)

            %{
              name: squadron_name,
              status: derive_status(sq_agents),
              swarms: swarms,
              agents: Enum.map(direct_agents, &format_agent/1)
            }
          end)
          |> Enum.sort_by(& &1.name)

        %{
          id: formation_id,
          name: formation_id,
          agent_count: length(formation_agents),
          squadrons: squadrons,
          source: :live
        }
      end)

    live_ids = MapSet.new(live_formations, & &1.id)
    upm_only = Enum.filter(upm_formations, &(!MapSet.member?(live_ids, &1.id)))

    upm_trees =
      Enum.map(upm_only, fn f ->
        squadrons =
          (f.squadrons || [])
          |> Enum.map(fn sq ->
            agents_list =
              (sq["agents"] || sq[:agents] || [])
              |> Enum.map(fn a ->
                %{
                  id: a["id"] || a[:id] || "?",
                  name: a["id"] || a[:id] || "?",
                  status: a["status"] || a[:status] || "idle",
                  story_id: a["story_id"] || a[:story_id],
                  role: a["role"] || a[:role],
                  wave: nil,
                  wave_number: nil,
                  wave_total: nil,
                  swarm: nil,
                  cluster: nil,
                  agent_type: nil,
                  work_item_title: nil,
                  plane_issue_id: nil,
                  parent_id: nil,
                  member_count: nil
                }
              end)

            sq_status = sq["status"] || sq[:status] || "idle"

            %{
              name: sq["name"] || sq[:name] || sq["id"] || sq[:id] || "?",
              status: sq_status,
              swarms: [],
              agents: agents_list
            }
          end)
          |> Enum.sort_by(& &1.name)

        all_sq_statuses = Enum.map(squadrons, & &1.status)

        formation_status =
          cond do
            Enum.all?(all_sq_statuses, &(&1 in ["complete", "pass", "done"])) -> "complete"
            Enum.any?(all_sq_statuses, &(&1 == "error")) -> "error"
            Enum.any?(all_sq_statuses, &(&1 in ["active", "running"])) -> "active"
            true -> f.status || "idle"
          end

        total_agents = Enum.sum(Enum.map(squadrons, &squadron_total_count/1))

        %{
          id: f.id,
          name: f.id,
          agent_count: total_agents,
          squadrons: squadrons,
          status: formation_status,
          registered_at: f.registered_at,
          source: :upm
        }
      end)

    all_known_ids = MapSet.union(live_ids, MapSet.new(upm_only, & &1.id))

    notif_trees =
      AgentRegistry.get_notifications()
      |> Enum.filter(&(Map.get(&1, :formation_id) not in [nil, ""]))
      |> Enum.group_by(&Map.get(&1, :formation_id))
      |> Enum.reject(fn {fid, _} -> MapSet.member?(all_known_ids, fid) end)
      |> Enum.map(fn {formation_id, notifs} ->
        sq_names =
          notifs
          |> Enum.map(&Map.get(&1, :title, ""))
          |> Enum.flat_map(fn title ->
            case Regex.run(~r/^([A-Za-z]+):\s/, title) do
              [_, name] -> [name]
              _ -> []
            end
          end)
          |> Enum.uniq()

        squadrons =
          case sq_names do
            [] ->
              []

            names ->
              Enum.map(names, fn name ->
                sq_notifs =
                  Enum.filter(notifs, &String.starts_with?(Map.get(&1, :title, ""), name <> ":"))

                status =
                  if Enum.any?(sq_notifs, &(&1.type in ["success", "ok"])),
                    do: "complete",
                    else: "active"

                %{name: name, status: status, swarms: [], agents: []}
              end)
          end

        last_notif = List.first(notifs)

        status =
          cond do
            Enum.any?(notifs, &String.contains?(Map.get(&1, :title, ""), "Complete")) -> "complete"
            Enum.any?(notifs, &(&1.type == "error")) -> "error"
            true -> "active"
          end

        %{
          id: formation_id,
          name: formation_id,
          agent_count: 0,
          squadrons: squadrons,
          status: status,
          registered_at: Map.get(last_notif || %{}, :timestamp),
          source: :notifications
        }
      end)

    (live_formations ++ upm_trees ++ notif_trees)
    |> Enum.sort_by(& &1.name)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp format_agent(a) do
    meta = a[:metadata] || %{}

    %{
      id: a.id,
      name: a.name,
      status: a.status,
      role: a[:role],
      story_id: a[:story_id],
      wave: a[:wave],
      wave_number: a[:wave_number] || meta["wave_number"],
      wave_total: a[:wave_total] || meta["wave_total"],
      swarm: a[:swarm],
      cluster: a[:cluster],
      agent_type: a[:agent_type] || meta["agent_type"],
      work_item_title: a[:work_item_title] || meta["work_item_title"],
      plane_issue_id: a[:plane_issue_id] || meta["plane_issue_id"],
      parent_id: a[:parent_id],
      member_count: a[:member_count]
    }
  end

  defp agent_to_node(agent) do
    %{
      id: agent.id,
      name: agent.name,
      level: "agent",
      status: agent.status,
      role: agent[:role],
      story_id: agent[:story_id],
      agent_type: agent[:agent_type],
      wave_number: agent[:wave_number],
      work_item_title: agent[:work_item_title]
    }
  end

  defp derive_status(agents) do
    cond do
      Enum.any?(agents, &(&1[:status] == "error")) -> "error"
      Enum.any?(agents, &(&1[:status] == "active")) -> "active"
      Enum.all?(agents, &(&1[:status] in ["pass", "complete", "done"])) and agents != [] ->
        "complete"

      true ->
        "idle"
    end
  end

  defp squadron_total_count(%{agents: direct, swarms: swarms}) do
    length(direct) + Enum.sum(Enum.map(swarms, &swarm_total_count/1))
  end

  defp squadron_total_count(%{agents: direct}), do: length(direct)

  defp swarm_total_count(%{agents: direct, clusters: clusters}) do
    length(direct) + Enum.sum(Enum.map(clusters, fn c -> length(c.agents) end))
  end

  defp swarm_total_count(%{agents: direct}), do: length(direct)

  defp formation_status(%{status: status}) when status in ["complete", "pass", "done"],
    do: "complete"

  defp formation_status(formation) do
    all_agents = all_formation_agents(formation)

    cond do
      Enum.any?(all_agents, &(&1.status == "error")) -> "error"
      Enum.any?(all_agents, &(&1.status == "active")) -> "active"
      Enum.all?(all_agents, &(&1.status in ["pass", "complete", "done"])) and all_agents != [] ->
        "complete"

      true ->
        formation[:status] || "idle"
    end
  end

  defp all_formation_agents(formation) do
    Enum.flat_map(formation.squadrons, fn sq ->
      direct = sq.agents

      swarm_agents =
        Enum.flat_map(Map.get(sq, :swarms, []), fn sw ->
          sw.agents ++ Enum.flat_map(Map.get(sw, :clusters, []), & &1.agents)
        end)

      direct ++ swarm_agents
    end)
  end

  defp formation_wave_count(formation) do
    formation
    |> all_formation_agents()
    |> Enum.map(& &1[:wave_number])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length()
  end

  defp derive_total_waves(formations) do
    formations
    |> Enum.flat_map(&all_formation_agents/1)
    |> Enum.map(& &1[:wave_number])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length()
  end

  defp status_tone("active"), do: "ok"
  defp status_tone("complete"), do: "info"
  defp status_tone("pass"), do: "info"
  defp status_tone("done"), do: "info"
  defp status_tone("error"), do: "err"
  defp status_tone(_idle), do: "neutral"

  defp source_label(:live), do: "live"
  defp source_label(:upm), do: "reg"
  defp source_label(:notifications), do: "notif"
  defp source_label(_), do: "unknown"

  defp formation_short_name(name) when byte_size(name) > 16 do
    name |> String.slice(0, 14) |> Kernel.<>("…")
  end

  defp formation_short_name(name), do: name

  defp format_registered_at(%{registered_at: ts}) when not is_nil(ts) do
    case ts do
      %DateTime{} -> Calendar.strftime(ts, "%b %d %H:%M")
      %NaiveDateTime{} -> Calendar.strftime(ts, "%b %d %H:%M")
      str when is_binary(str) -> String.slice(str, 0, 16)
      _ -> "—"
    end
  end

  defp format_registered_at(_), do: "—"

  # Map formation hierarchy levels to graph_node role atoms
  defp formation_level_role("formation"), do: "orchestrator"
  defp formation_level_role("squadron"), do: "squadron_lead"
  defp formation_level_role("swarm"), do: "swarm_agent"
  defp formation_level_role("cluster"), do: "cluster_agent"
  defp formation_level_role(_), do: "individual"
end
