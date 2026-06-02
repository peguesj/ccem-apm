defmodule ApmWeb.FormationLive do
  @moduledoc """
  LiveView for visualizing formation hierarchy (formation > squadron > swarm > cluster > agent)
  using a D3.js tree layout with real-time PubSub updates.

  All 5 hierarchy levels are rendered: swarm and cluster nodes are built from
  agent metadata fields `:swarm` and `:cluster`. Each agent node carries full
  metadata (agent_type, wave_number, work_item_title, plane_issue_id, parent_id).
  The Inspector panel shows a hierarchy breadcrumb and all available metadata.
  """

  use ApmWeb, :live_view


  alias Apm.AgentRegistry
  alias Apm.UpmStore

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:agents")
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:upm")
      # US-018: EventBus subscriptions for AG-UI formation events
      Apm.AgUi.EventBus.subscribe("lifecycle:*")
      # Defer the initial push_event until after the JS hook is mounted (150ms grace)
      Process.send_after(self(), :push_graph, 150)
    end

    agents = AgentRegistry.list_agents()
    upm_formations = try do UpmStore.list_formations() catch :exit, _ -> [] end
    formations = build_formation_tree(agents, upm_formations)
    active_formation = try do UpmStore.get_active_formation() catch :exit, _ -> nil end

    socket =
      socket
      |> assign(:page_title, "Formations")
      |> assign(:agents, agents)
      |> assign(:all_agents, agents)
      |> assign(:formations, formations)
      |> assign(:active_formation, active_formation)
      |> assign(:selected_node, nil)
      |> assign(:wave_progress, %{current_wave: 0, total_waves: 0, agents_in_wave: 0, agents_complete: 0})
      |> assign(:active_skill_count, skill_count())
      |> assign(:view_mode, "graph_td")
      |> assign(:agent_filter, "")
      |> assign(:role_filter, "")
      |> assign(:scope, nil)
      |> assign(:dot_source, nil)
      |> assign(:dot_formation_id, nil)
      |> assign(:dot_executable, System.find_executable("dot"))

    {:ok, socket |> assign(:sidebar_collapsed, false)
     |> assign(:inspector_open, false)
     |> ApmWeb.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = params["scope"]
    agents = AgentRegistry.list_agents()
    upm_formations = try do UpmStore.list_formations() catch :exit, _ -> [] end
    all_formations = build_formation_tree(agents, upm_formations)

    formations =
      if scope do
        Enum.filter(all_formations, &(&1.id == scope))
      else
        all_formations
      end

    socket =
      socket
      |> assign(:scope, scope)
      |> assign(:formations, formations)
      |> assign(:all_agents, agents)
      |> assign(:agents, agents)
      |> push_formation_graph(formations)

    socket =
      if scope do
        push_event(socket, "formation:scope", %{scope: scope})
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav current_path="/formation" skill_count={@active_skill_count} />
      </:sidebar>
      <:main>

      <%!-- Main content --%>
      <div class="ccem-formation-hierarchy flex-1 flex flex-col overflow-hidden">
        <%!-- Top bar --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0 relative z-10">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Formation Hierarchy</h2>
            <div class="badge badge-sm badge-ghost">
              {length(@formations)} formations
            </div>
            <div class="badge badge-sm badge-ghost">
              {Enum.sum(Enum.map(@formations, & &1.agent_count))} agents
            </div>
          </div>
          <div class="flex items-center gap-2">
            <%!-- View mode toggle --%>
            <div class="flex gap-0.5 bg-base-300 rounded-lg p-0.5" role="tablist" aria-label="Formation view mode">
              <button
                phx-click="set_view_mode" phx-value-mode="graph_td"
                class={["btn btn-xs gap-1", if(@view_mode == "graph_td", do: "btn-primary", else: "btn-ghost")]}
                role="tab" aria-selected={@view_mode == "graph_td"}
              >
                <.icon name="hero-arrow-down" class="size-3" /> TD
              </button>
              <button
                phx-click="set_view_mode" phx-value-mode="graph_lr"
                class={["btn btn-xs gap-1", if(@view_mode == "graph_lr", do: "btn-primary", else: "btn-ghost")]}
                role="tab" aria-selected={@view_mode == "graph_lr"}
              >
                <.icon name="hero-arrow-right" class="size-3" /> LR
              </button>
              <button
                phx-click="set_view_mode" phx-value-mode="list"
                class={["btn btn-xs gap-1", if(@view_mode == "list", do: "btn-primary", else: "btn-ghost")]}
                role="tab" aria-selected={@view_mode == "list"}
              >
                <.icon name="hero-list-bullet" class="size-3" /> List
              </button>
              <button
                phx-click="set_view_mode" phx-value-mode="cards"
                class={["btn btn-xs gap-1", if(@view_mode == "cards", do: "btn-primary", else: "btn-ghost")]}
                role="tab" aria-selected={@view_mode == "cards"}
              >
                <.icon name="hero-squares-2x2" class="size-3" /> Cards
              </button>
              <button
                phx-click="set_view_mode" phx-value-mode="tb"
                class={["btn btn-xs gap-1", if(@view_mode == "tb", do: "btn-primary", else: "btn-ghost")]}
                role="tab" aria-selected={@view_mode == "tb"}
              >
                <.icon name="hero-view-columns" class="size-3" /> TB
              </button>
              <button
                phx-click="set_view_mode" phx-value-mode="dot"
                class={["btn btn-xs gap-1", if(@view_mode == "dot", do: "btn-primary", else: "btn-ghost")]}
                role="tab" aria-selected={@view_mode == "dot"}
              >
                <.icon name="hero-code-bracket" class="size-3" /> DOT
              </button>
            </div>
            <button phx-click="refresh" class="btn btn-ghost btn-xs">
              <.icon name="hero-arrow-path" class="size-3" /> Refresh
            </button>
          </div>
        </header>

        <%!-- Body --%>
        <div class="flex-1 flex overflow-hidden">
          <%!-- Main view area --%>
          <div class="flex-1 overflow-hidden relative">
            <%!-- Graph TD / Graph LR / TB (D3 hook) --%>
            <div
              :if={@view_mode in ["graph_td", "graph_lr", "tb"]}
              id="formation-graph"
              class="w-full h-full"
              style="background: #151b28;"
              phx-hook="FormationGraph"
              data-orientation={@view_mode}
              phx-update="ignore"
            >
            </div>

            <%!-- Edge type legend (graph views only) --%>
            <div :if={@view_mode in ["graph_td", "graph_lr", "tb"]} class="absolute bottom-2 left-2 z-10">
              <div class="collapse collapse-arrow bg-base-200 mt-2 shadow-md">
                <input type="checkbox" checked />
                <div class="collapse-title text-sm font-medium">Edge Legend</div>
                <div class="collapse-content">
                  <div class="flex flex-wrap gap-4 text-xs">
                    <div class="flex items-center gap-2">
                      <svg width="30" height="10"><line x1="0" y1="5" x2="30" y2="5" stroke="#a3a3a3" stroke-width="1.5" stroke-dasharray="5,3"/></svg>
                      <span>Hierarchy</span>
                    </div>
                    <div class="flex items-center gap-2">
                      <svg width="30" height="10"><line x1="0" y1="5" x2="30" y2="5" stroke="#3b82f6" stroke-width="1.2" stroke-dasharray="4,4"/></svg>
                      <span>Pub/Sub</span>
                    </div>
                    <div class="flex items-center gap-2">
                      <svg width="30" height="10"><line x1="0" y1="5" x2="30" y2="5" stroke="#22c55e" stroke-width="1.2" stroke-dasharray="6,3"/></svg>
                      <span>Aggregation</span>
                    </div>
                    <div class="flex items-center gap-2">
                      <svg width="30" height="10"><line x1="0" y1="5" x2="30" y2="5" stroke="#f97316" stroke-width="2.5"/></svg>
                      <span>Data Export</span>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Hierarchical List view --%>
            <div :if={@view_mode == "list"} class="w-full h-full overflow-y-auto p-4 bg-base-300">
              <.formation_list_view
                formations={@formations}
                agents={@agents}
                agent_filter={@agent_filter}
                role_filter={@role_filter}
              />
            </div>

            <%!-- Card Grid view --%>
            <div :if={@view_mode == "cards"} class="w-full h-full overflow-y-auto p-4 bg-base-300">
              <.formation_cards_view formations={@formations} agents={@agents} />
            </div>

            <%!-- DOT source view --%>
            <div :if={@view_mode == "dot"} class="w-full h-full overflow-y-auto p-4 bg-base-300">
              <div class="max-w-4xl mx-auto space-y-4">
                <%!-- Formation selector --%>
                <div class="flex flex-wrap gap-2 items-center">
                  <span class="text-xs text-base-content/50 uppercase tracking-wider">Formation</span>
                  <%= for formation <- @formations do %>
                    <button
                      phx-click="load_dot"
                      phx-value-id={formation.id}
                      class={["btn btn-xs", if(@dot_formation_id == formation.id, do: "btn-primary", else: "btn-outline")]}
                    >
                      {formation.name}
                    </button>
                  <% end %>
                  <div :if={@formations == []} class="text-xs text-base-content/30 italic">
                    No formations available.
                  </div>
                </div>

                <%!-- DOT output --%>
                <div :if={@dot_source} class="space-y-2">
                  <div class="flex items-center gap-2">
                    <span class="text-xs font-mono text-base-content/50">
                      {"/api/formations/#{@dot_formation_id}/dot"}
                    </span>
                    <button
                      phx-click="copy_dot"
                      class="btn btn-xs btn-ghost"
                      title="Copy DOT source"
                    >
                      <.icon name="hero-clipboard" class="size-3" /> Copy
                    </button>
                    <a
                      :if={@dot_executable}
                      href={"/api/formations/#{@dot_formation_id}/dot"}
                      download={"#{@dot_formation_id}.dot"}
                      class="btn btn-xs btn-ghost"
                      title="Download .dot file — pipe through `dot -Tpng` to render"
                    >
                      <.icon name="hero-arrow-down-tray" class="size-3" /> Download (.dot)
                    </a>
                  </div>
                  <pre
                    id="dot-source-block"
                    class="bg-base-200 rounded-lg p-4 text-xs font-mono text-base-content/80 overflow-x-auto whitespace-pre border border-base-300"
                    phx-hook="CopyDot"
                  ><code>{@dot_source}</code></pre>
                  <p :if={@dot_executable} class="text-[10px] text-base-content/30 font-mono">
                    Render: <span class="text-base-content/50">dot -Tpng &lt;file.dot&gt; -o formation.png</span>
                  </p>
                </div>

                <div :if={is_nil(@dot_source) and @formations != []} class="text-xs text-base-content/30 text-center py-8">
                  Select a formation above to generate its DOT source.
                </div>
              </div>
            </div>

            <%!-- Empty state (only shown in graph modes) --%>
            <div
              :if={@formations == [] and @view_mode in ["graph_td", "graph_lr", "tb"]}
              class="absolute inset-0 flex items-center justify-center pointer-events-none"
            >
              <div class="text-center">
                <.icon name="hero-rectangle-group" class="size-16 text-base-content/20 mx-auto mb-4" />
                <h3 class="text-lg font-semibold text-base-content/40">No Formations Active</h3>
                <p class="text-sm text-base-content/30 mt-1 max-w-md">
                  Formations appear when agents are registered via <code class="font-mono text-xs">/formation deploy</code>
                  or when agents heartbeat with <code class="font-mono text-xs">formation_id</code> metadata.
                </p>
                <p class="text-xs text-base-content/20 mt-2">
                  POST /api/upm/register with formation manifest to populate this view.
                </p>
              </div>
            </div>
          </div>

          <%!-- Detail panel --%>
          <div class="w-72 border-l border-base-300 bg-base-200 flex flex-col flex-shrink-0 overflow-y-auto">
            <%!-- Inspector header --%>
            <div class="p-4 border-b border-base-300">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                Inspector
              </h3>
            </div>

            <%!-- Wave progress (shown when a formation with wave data is selected) --%>
            <div :if={@wave_progress.total_waves > 0} class="px-4 py-3 border-b border-base-300 bg-base-300/30">
              <div class="text-xs text-base-content/50 uppercase tracking-wider mb-1">Wave Progress</div>
              <div class="text-sm font-mono text-base-content/80">
                Wave <%= @wave_progress.current_wave %> of <%= @wave_progress.total_waves %>
                &mdash; <%= @wave_progress.agents_complete %>/<%= @wave_progress.agents_in_wave %> agents
              </div>
              <div class="h-1.5 bg-base-300 rounded mt-2">
                <div
                  class="h-1.5 bg-success rounded transition-all duration-300"
                  style={"width:#{wave_percent(@wave_progress)}%"}
                ></div>
              </div>
            </div>

            <%!-- Selected node details --%>
            <div class="p-4 border-b border-base-300">
              <div :if={@selected_node == nil} class="text-center text-base-content/30 py-8 text-xs">
                Click a node to inspect
              </div>
              <div :if={@selected_node} class="space-y-3">
                <%!-- Level + Name --%>
                <div>
                  <div class={["inline-block px-2 py-0.5 rounded text-xs font-semibold mb-2", level_badge(@selected_node.level)]}>
                    {@selected_node.level}
                  </div>
                  <%!-- Agent type badge --%>
                  <span
                    :if={@selected_node[:agent_type] && @selected_node[:agent_type] not in [nil, "individual"]}
                    class="inline-block ml-1 px-1.5 py-0.5 rounded text-[9px] font-mono font-bold bg-violet-900/40 text-violet-300 border border-violet-700/50"
                  >
                    {@selected_node.agent_type}
                  </span>
                  <h3 class="text-sm font-bold mt-1">{@selected_node.name}</h3>
                </div>

                <%!-- Hierarchy breadcrumb --%>
                <div
                  :if={@selected_node[:formation_id] || @selected_node[:squadron] || @selected_node[:swarm]}
                  class="text-[9px] font-mono leading-loose bg-base-300/40 rounded px-2 py-1.5"
                >
                  <span :if={@selected_node[:formation_id]} class="text-accent/70">{@selected_node[:formation_id]}</span>
                  <span :if={@selected_node[:squadron]}> <span class="text-base-content/30">›</span> <span class="text-info/70">{@selected_node.squadron}</span></span>
                  <span :if={@selected_node[:swarm]}> <span class="text-base-content/30">›</span> <span class="text-success/70">{@selected_node.swarm}</span></span>
                  <span :if={@selected_node[:cluster]}> <span class="text-base-content/30">›</span> <span class="text-secondary/70">{@selected_node.cluster}</span></span>
                  <span :if={@selected_node.level == "agent"}> <span class="text-base-content/30">›</span> <span class="text-primary/70">{@selected_node.name}</span></span>
                </div>

                <%!-- Core fields --%>
                <div class="space-y-1.5 text-xs">
                  <div :if={@selected_node[:id]} class="flex justify-between gap-2">
                    <span class="text-base-content/50 flex-shrink-0">ID</span>
                    <span class="font-mono text-[9px] text-right truncate">{@selected_node.id}</span>
                  </div>
                  <div :if={@selected_node[:status]} class="flex justify-between">
                    <span class="text-base-content/50">Status</span>
                    <span class={["badge badge-xs", status_badge(@selected_node.status)]}>{@selected_node.status}</span>
                  </div>
                  <div :if={@selected_node[:member_count] && @selected_node[:member_count] > 0} class="flex justify-between">
                    <span class="text-base-content/50">Members</span>
                    <span>{@selected_node.member_count}</span>
                  </div>

                  <%!-- Story / Work Item --%>
                  <div :if={@selected_node[:story_id]} class="flex justify-between">
                    <span class="text-base-content/50">Story</span>
                    <span class="badge badge-xs badge-primary badge-outline font-mono">{@selected_node.story_id}</span>
                  </div>
                  <div :if={@selected_node[:work_item_title] && !@selected_node[:story_id]} class="flex justify-between gap-2">
                    <span class="text-base-content/50 flex-shrink-0">Work Item</span>
                    <span class="text-[10px] text-right truncate max-w-[140px]">{@selected_node.work_item_title}</span>
                  </div>
                  <div :if={@selected_node[:plane_issue_id]} class="flex justify-between gap-2">
                    <span class="text-base-content/50 flex-shrink-0">Plane</span>
                    <span class="font-mono text-[9px] text-info truncate">{@selected_node.plane_issue_id}</span>
                  </div>

                  <%!-- Wave info --%>
                  <div :if={@selected_node[:wave_number]} class="flex justify-between">
                    <span class="text-base-content/50">Wave</span>
                    <span class="font-mono text-[10px]">
                      {@selected_node.wave_number}<span :if={@selected_node[:wave_total]} class="text-base-content/40">/{@selected_node.wave_total}</span>
                    </span>
                  </div>
                  <div :if={!@selected_node[:wave_number] && @selected_node[:wave]} class="flex justify-between">
                    <span class="text-base-content/50">Wave</span>
                    <span>{@selected_node.wave}</span>
                  </div>

                  <%!-- Role --%>
                  <div :if={@selected_node[:role]} class="flex justify-between gap-2">
                    <span class="text-base-content/50 flex-shrink-0">Role</span>
                    <span class="text-[10px] text-right truncate max-w-[140px]">{@selected_node.role}</span>
                  </div>

                  <%!-- Parent --%>
                  <div :if={@selected_node[:parent_id]} class="flex justify-between gap-2">
                    <span class="text-base-content/50 flex-shrink-0">Parent</span>
                    <span class="font-mono text-[9px] text-base-content/50 truncate">{@selected_node.parent_id}</span>
                  </div>

                  <%!-- Swarm / Cluster assignments (when viewing non-grouped levels) --%>
                  <div :if={@selected_node[:swarm] && @selected_node.level != "swarm"} class="flex justify-between">
                    <span class="text-base-content/50">Swarm</span>
                    <span class="text-success text-[10px]">{@selected_node.swarm}</span>
                  </div>
                  <div :if={@selected_node[:cluster] && @selected_node.level != "cluster"} class="flex justify-between">
                    <span class="text-base-content/50">Cluster</span>
                    <span class="text-secondary text-[10px]">{@selected_node.cluster}</span>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Formation tree sidebar --%>
            <div class="p-4">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3">
                Formation Tree
              </h3>
              <div class="space-y-2">
                <div :for={formation <- @formations} class="space-y-0.5">
                  <%!-- Formation row --%>
                  <button
                    class="w-full text-left px-2 py-1 rounded text-xs font-semibold text-accent hover:bg-base-300 flex items-center gap-1"
                    phx-click="select_formation"
                    phx-value-id={formation.id}
                  >
                    <span class={["w-1.5 h-1.5 rounded-full flex-shrink-0", agent_dot(formation_status(formation))]}></span>
                    <span class="flex-1 truncate">{formation.name}</span>
                    <span class="badge badge-xs badge-ghost">{formation.agent_count}</span>
                    <span :if={formation[:source] == :upm} class="badge badge-xs badge-outline opacity-50">reg</span>
                  </button>

                  <%!-- Squadrons --%>
                  <div :for={squadron <- formation.squadrons} class="pl-3">
                    <button
                      class="w-full text-left px-2 py-0.5 rounded text-[10px] text-info hover:bg-base-300 flex items-center gap-1"
                      phx-click="select_squadron"
                      phx-value-formation={formation.id}
                      phx-value-squadron={squadron.name}
                    >
                      <span class={["w-1 h-1 rounded-full flex-shrink-0", agent_dot(squadron[:status] || "idle")]}></span>
                      <span class="flex-1 truncate">{squadron.name}</span>
                      <span class="text-base-content/30 text-[9px]">{squadron_total_count(squadron)}</span>
                    </button>

                    <%!-- Direct squadron agents (no swarm) --%>
                    <div :for={agent <- squadron.agents} class="pl-3">
                      <.agent_tree_row agent={agent} />
                    </div>

                    <%!-- Swarms --%>
                    <div :for={swarm <- Map.get(squadron, :swarms, [])} class="pl-3">
                      <button
                        class="w-full text-left px-2 py-0.5 rounded text-[10px] text-success hover:bg-base-300 flex items-center gap-1"
                        phx-click="select_swarm"
                        phx-value-formation={formation.id}
                        phx-value-squadron={squadron.name}
                        phx-value-swarm={swarm.name}
                      >
                        <span class={["w-1 h-1 rounded-full flex-shrink-0", agent_dot(swarm[:status] || "idle")]}></span>
                        <span class="text-[9px] text-base-content/30 mr-0.5">swarm</span>
                        <span class="flex-1 truncate">{swarm.name}</span>
                        <span class="text-base-content/30 text-[9px]">{swarm_total_count(swarm)}</span>
                      </button>

                      <%!-- Direct swarm agents (no cluster) --%>
                      <div :for={agent <- Map.get(swarm, :agents, [])} class="pl-3">
                        <.agent_tree_row agent={agent} />
                      </div>

                      <%!-- Clusters --%>
                      <div :for={cluster <- Map.get(swarm, :clusters, [])} class="pl-3">
                        <button
                          class="w-full text-left px-2 py-0.5 rounded text-[10px] text-secondary hover:bg-base-300 flex items-center gap-1"
                          phx-click="select_cluster"
                          phx-value-formation={formation.id}
                          phx-value-squadron={squadron.name}
                          phx-value-swarm={swarm.name}
                          phx-value-cluster={cluster.name}
                        >
                          <span class={["w-1 h-1 rounded-full flex-shrink-0", agent_dot(cluster[:status] || "idle")]}></span>
                          <span class="text-[9px] text-base-content/30 mr-0.5">cluster</span>
                          <span class="flex-1 truncate">{cluster.name}</span>
                          <span class="text-base-content/30 text-[9px]">{length(cluster.agents)}</span>
                        </button>

                        <%!-- Cluster agents --%>
                        <div :for={agent <- cluster.agents} class="pl-3">
                          <.agent_tree_row agent={agent} />
                        </div>
                      </div>
                    </div>
                  </div>
                </div>

                <div :if={@formations == []} class="text-xs text-base-content/30 py-4 text-center">
                  No formations registered.<br/>
                  <span class="text-[9px]">Use /formation deploy to create one.</span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    <.wizard page="formation" />
      </:main>
    </.page_layout>
    """
  end

  # Reusable agent row with type badge + status dot + story/wave
  attr :agent, :map, required: true
  defp agent_tree_row(assigns) do
    ~H"""
    <button
      class="w-full text-left px-2 py-0.5 rounded text-[10px] text-base-content/60 hover:bg-base-300 flex items-center gap-1"
      phx-click="select_agent"
      phx-value-id={@agent.id}
    >
      <span class={["w-1.5 h-1.5 rounded-full flex-shrink-0", agent_dot(@agent.status)]}></span>
      <span :if={@agent[:agent_type] && @agent[:agent_type] not in [nil, "individual"]}
            class="text-[8px] font-mono text-violet-400/80 mr-0.5 flex-shrink-0">
        {agent_type_abbr(@agent.agent_type)}
      </span>
      <span class="flex-1 truncate">{@agent.name}</span>
      <span :if={@agent[:story_id]} class="font-mono text-[9px] text-primary/70 flex-shrink-0">{@agent.story_id}</span>
      <span :if={@agent[:wave_number]} class="text-[8px] text-base-content/30 flex-shrink-0">W{@agent.wave_number}</span>
    </button>
    """
  end


  # --- List View Component ---

  attr :formations, :list, required: true
  attr :agents, :list, required: true
  attr :agent_filter, :string, required: true
  attr :role_filter, :string, required: true

  defp formation_list_view(assigns) do
    ~H"""
    <div class="space-y-2 max-w-4xl mx-auto">
      <div class="flex gap-2 mb-4">
        <input
          type="text"
          placeholder="Filter agents\u2026"
          value={@agent_filter}
          phx-keyup="filter_agents"
          phx-debounce="200"
          class="input input-sm input-bordered flex-1 bg-base-200"
        />
        <select phx-change="filter_role" class="select select-sm select-bordered bg-base-200">
          <option value="" selected={@role_filter == ""}>All roles</option>
          <option value="orchestrator" selected={@role_filter == "orchestrator"}>Orchestrator</option>
          <option value="squadron_lead" selected={@role_filter == "squadron_lead"}>Squadron Lead</option>
          <option value="swarm_agent" selected={@role_filter == "swarm_agent"}>Swarm Agent</option>
          <option value="cluster_agent" selected={@role_filter == "cluster_agent"}>Cluster Agent</option>
          <option value="individual" selected={@role_filter == "individual"}>Individual</option>
        </select>
      </div>

      <div :if={@formations == []} class="text-center text-base-content/30 py-12 text-sm">
        No formations active.
      </div>

      <%= for formation <- @formations do %>
        <% all_ags = all_formation_agents(formation) %>
        <% filtered = filter_agents_list(all_ags, @agent_filter, @role_filter) %>
        <details class="border border-base-300 rounded-lg" open>
          <summary class="px-4 py-2 cursor-pointer font-mono text-sm bg-base-300/50 rounded-t-lg flex items-center gap-2 select-none hover:bg-base-300 transition-colors">
            <span class={["w-2 h-2 rounded-full flex-shrink-0", agent_dot(formation_status(formation))]}></span>
            <span class="flex-1 truncate text-accent">{formation.name}</span>
            <span class="badge badge-sm badge-primary">{length(filtered)}</span>
            <span :if={formation[:source] == :upm} class="badge badge-xs badge-outline opacity-50">reg</span>
          </summary>
          <div class="p-3">
            <%= for {role_label, role_agents} <- list_group_by_role(filtered) do %>
              <div class="mb-3 last:mb-0">
                <div class="text-[10px] font-semibold uppercase tracking-wider mb-1 pl-2 flex items-center gap-1.5">
                  <span class={list_role_color(role_label)}>{role_label}</span>
                  <span class="text-base-content/20">({length(role_agents)})</span>
                </div>
                <div class="pl-2 border-l-2 border-base-300 space-y-0.5">
                  <%= for agent <- role_agents do %>
                    <button
                      class="w-full text-left px-2 py-1 rounded text-xs text-base-content/70 hover:bg-base-300 flex items-center gap-2 transition-colors"
                      phx-click="select_agent"
                      phx-value-id={agent.id}
                    >
                      <span class={["w-2 h-2 rounded-full flex-shrink-0", agent_dot(agent.status)]}></span>
                      <span class="font-mono text-[9px] text-base-content/40 flex-shrink-0 hidden sm:inline">{String.slice(agent.id || "", 0, 16)}</span>
                      <span class="flex-1 truncate">{agent[:work_item_title] || agent[:role] || agent.name}</span>
                      <span :if={agent[:wave_number]} class="badge badge-xs badge-ghost flex-shrink-0">W{agent.wave_number}</span>
                      <span :if={agent[:story_id]} class="font-mono text-[9px] text-primary/70 flex-shrink-0">{agent.story_id}</span>
                    </button>
                  <% end %>
                </div>
              </div>
            <% end %>
            <div :if={filtered == []} class="text-xs text-base-content/30 text-center py-4">
              No agents match the current filter.
            </div>
          </div>
        </details>
      <% end %>
    </div>
    """
  end

  # --- Cards View Component ---

  attr :formations, :list, required: true
  attr :agents, :list, required: true

  defp formation_cards_view(assigns) do
    ~H"""
    <div class="space-y-8 max-w-6xl mx-auto">
      <div :if={@formations == []} class="text-center text-base-content/30 py-12 text-sm">
        No formations active.
      </div>
      <%= for {namespace, ns_agents} <- cards_group_by_namespace(@formations) do %>
        <div>
          <h3 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3 flex items-center gap-2">
            <.icon name="hero-folder" class="w-3.5 h-3.5" />
            <span>{namespace}</span>
            <span class="badge badge-sm badge-ghost">{length(ns_agents)}</span>
          </h3>
          <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-3">
            <%= for agent <- ns_agents do %>
              <button
                class={["card card-compact bg-base-200 border text-left hover:bg-base-300 transition-colors", cards_agent_border(agent.status)]}
                phx-click="select_agent"
                phx-value-id={agent.id}
              >
                <div class="card-body gap-1.5">
                  <div class="flex items-center justify-between gap-1">
                    <span class={["badge badge-xs truncate max-w-[100px]", cards_role_badge(agent[:formation_role] || agent[:role])]}>
                      {agent[:formation_role] || agent[:role] || "agent"}
                    </span>
                    <span class={["badge badge-xs flex-shrink-0", status_badge(agent.status)]}>
                      {agent.status}
                    </span>
                  </div>
                  <p class="font-mono text-[9px] text-base-content/40 truncate">{agent.id}</p>
                  <p class="text-xs font-medium line-clamp-2 text-base-content/80">
                    {agent[:work_item_title] || agent[:role] || agent.name}
                  </p>
                  <div :if={agent[:wave_number] || agent[:wave]} class="text-[10px] text-base-content/40">
                    Wave {agent[:wave_number] || agent[:wave]}
                  </div>
                </div>
              </button>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # --- Events ---

  @impl true
  def handle_event("refresh", _params, socket) do
    agents = AgentRegistry.list_agents()
    upm_formations = try do UpmStore.list_formations() catch :exit, _ -> [] end
    formations = build_formation_tree(agents, upm_formations)
    {:noreply,
     socket
     |> assign(:agents, agents)
     |> assign(:all_agents, agents)
     |> assign(:formations, formations)
     |> push_formation_graph(formations)}
  end

  def handle_event("set_view_mode", %{"mode" => mode}, socket)
      when mode in ["graph_td", "graph_lr", "list", "cards", "tb"] do
    socket =
      if mode == "tb" do
        push_event(socket, "formation:layout", %{mode: "tb"})
      else
        socket
      end
    {:noreply, assign(socket, :view_mode, mode)}
  end

  def handle_event("set_view_mode", %{"mode" => "dot"}, socket) do
    {:noreply, assign(socket, :view_mode, "dot")}
  end

  def handle_event("set_view_mode", _params, socket), do: {:noreply, socket}

  def handle_event("load_dot", %{"id" => formation_id}, socket) do
    agents =
      AgentRegistry.list_agents()
      |> Enum.filter(fn a -> (a[:formation_id] || a["formation_id"]) == formation_id end)

    dot_source =
      if agents == [] do
        nil
      else
        Apm.FormationDot.generate(formation_id, agents)
      end

    {:noreply,
     socket
     |> assign(:dot_source, dot_source)
     |> assign(:dot_formation_id, formation_id)}
  end

  def handle_event("copy_dot", _params, socket) do
    {:noreply, push_event(socket, "copy_dot_source", %{})}
  end

  def handle_event("filter_agents", %{"value" => query}, socket) do
    filtered = filter_agents_list(socket.assigns.all_agents, query, socket.assigns.role_filter)
    {:noreply, assign(socket, agents: filtered, agent_filter: query)}
  end

  def handle_event("filter_role", %{"value" => role}, socket) do
    filtered = filter_agents_list(socket.assigns.all_agents, socket.assigns.agent_filter, role)
    {:noreply, assign(socket, agents: filtered, role_filter: role)}
  end

  def handle_event("select_formation", %{"id" => id}, socket) do
    formation = Enum.find(socket.assigns.formations, &(&1.id == id))
    node = if formation, do: %{
      level: "formation",
      name: formation.name,
      id: formation.id,
      member_count: formation.agent_count,
      status: formation_status(formation)
    }
    wave_progress = AgentRegistry.wave_progress(id)
    {:noreply, socket |> assign(:selected_node, node) |> assign(:wave_progress, wave_progress)}
  end

  def handle_event("select_squadron", %{"formation" => fid, "squadron" => name}, socket) do
    formation = Enum.find(socket.assigns.formations, &(&1.id == fid))
    squadron = if formation, do: Enum.find(formation.squadrons, &(&1.name == name))
    node = if squadron, do: %{
      level: "squadron",
      name: squadron.name,
      id: "#{fid}/#{name}",
      member_count: squadron_total_count(squadron),
      status: squadron[:status] || "idle",
      formation_id: fid
    }
    {:noreply, assign(socket, :selected_node, node)}
  end

  def handle_event("select_swarm", %{"formation" => fid, "squadron" => sq_name, "swarm" => sw_name}, socket) do
    formation = Enum.find(socket.assigns.formations, &(&1.id == fid))
    squadron = if formation, do: Enum.find(formation.squadrons, &(&1.name == sq_name))
    swarm = if squadron, do: Enum.find(Map.get(squadron, :swarms, []), &(&1.name == sw_name))
    node = if swarm, do: %{
      level: "swarm",
      name: swarm.name,
      id: "#{fid}/#{sq_name}/#{sw_name}",
      member_count: swarm_total_count(swarm),
      status: swarm[:status] || "idle",
      formation_id: fid,
      squadron: sq_name
    }
    {:noreply, assign(socket, :selected_node, node)}
  end

  def handle_event("select_cluster", %{"formation" => fid, "squadron" => sq_name, "swarm" => sw_name, "cluster" => cl_name}, socket) do
    formation = Enum.find(socket.assigns.formations, &(&1.id == fid))
    squadron = if formation, do: Enum.find(formation.squadrons, &(&1.name == sq_name))
    swarm = if squadron, do: Enum.find(Map.get(squadron, :swarms, []), &(&1.name == sw_name))
    cluster = if swarm, do: Enum.find(Map.get(swarm, :clusters, []), &(&1.name == cl_name))
    node = if cluster, do: %{
      level: "cluster",
      name: cluster.name,
      id: "#{fid}/#{sq_name}/#{sw_name}/#{cl_name}",
      member_count: length(cluster.agents),
      status: cluster[:status] || "idle",
      formation_id: fid,
      squadron: sq_name,
      swarm: sw_name
    }
    {:noreply, assign(socket, :selected_node, node)}
  end

  def handle_event("select_agent", %{"id" => id}, socket) do
    agent = AgentRegistry.get_agent(id)
    node = if agent do
      meta = agent[:metadata] || %{}
      %{
        level: "agent",
        name: agent.name,
        id: agent.id,
        status: agent.status,
        story_id: agent[:story_id],
        wave: agent[:wave],
        wave_number: agent[:wave_number] || meta["wave_number"],
        wave_total: agent[:wave_total] || meta["wave_total"],
        role: agent[:role],
        agent_type: agent[:agent_type] || meta["agent_type"],
        work_item_title: agent[:work_item_title] || meta["work_item_title"],
        plane_issue_id: agent[:plane_issue_id] || meta["plane_issue_id"],
        parent_id: agent[:parent_id],
        swarm: agent[:swarm],
        cluster: agent[:cluster],
        formation_id: agent[:formation_id],
        squadron: agent[:squadron],
        member_count: agent[:member_count]
      }
    end
    {:noreply, assign(socket, :selected_node, node)}
  end

  def handle_event("node_clicked", %{"id" => id, "level" => level}, socket) do
    case level do
      "formation" -> handle_event("select_formation", %{"id" => id}, socket)
      "agent"     -> handle_event("select_agent", %{"id" => id}, socket)
      _           -> {:noreply, socket}
    end
  end

  # --- PubSub ---

  @impl true
  def handle_info(:push_graph, socket) do
    {:noreply, push_formation_graph(socket, socket.assigns.formations)}
  end

  def handle_info({:agent_registered, _agent}, socket), do: refresh(socket)
  def handle_info({:agent_updated, _agent}, socket), do: refresh(socket)
  def handle_info({:agent_discovered, _, _}, socket), do: refresh(socket)
  def handle_info({:upm_session_registered, _}, socket), do: refresh(socket)
  def handle_info({:upm_agent_registered, _}, socket), do: refresh(socket)
  def handle_info({:formation_registered, _}, socket), do: refresh(socket)
  def handle_info({:formation_updated, _}, socket), do: refresh(socket)
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(socket) do
    agents = AgentRegistry.list_agents()
    upm_formations = try do UpmStore.list_formations() catch :exit, _ -> [] end
    formations = build_formation_tree(agents, upm_formations)
    filtered = filter_agents_list(agents, socket.assigns.agent_filter, socket.assigns.role_filter)
    {:noreply,
     socket
     |> assign(:agents, filtered)
     |> assign(:all_agents, agents)
     |> assign(:formations, formations)
     |> push_formation_graph(formations)}
  end

  # --- Formation Tree Builder ---

  # Build formation tree merging live AgentRegistry data with UpmStore registered formations.
  # Produces a 5-level hierarchy: formation > squadron > swarm > cluster > agent.
  # Agents with nil :swarm are placed directly under their squadron.
  # Agents with nil :cluster are placed directly under their swarm.
  defp build_formation_tree(agents, upm_formations) do
    # Live formations from AgentRegistry
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
            # Split by swarm: nil swarm → direct agents; named swarm → swarm node
            {direct_agents, swarm_map} =
              sq_agents
              |> Enum.group_by(& &1[:swarm])
              |> Map.pop(nil, [])

            swarms =
              Enum.map(swarm_map, fn {swarm_name, sw_agents} ->
                # Split by cluster within swarm
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

    # Merge UpmStore registered formations (completed/historical runs)
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
                %{id: a["id"] || a[:id] || "?", name: a["id"] || a[:id] || "?",
                  status: a["status"] || a[:status] || "idle",
                  story_id: a["story_id"] || a[:story_id], role: a["role"] || a[:role],
                  wave: nil, wave_number: nil, wave_total: nil,
                  swarm: nil, cluster: nil, agent_type: nil,
                  work_item_title: nil, plane_issue_id: nil, parent_id: nil, member_count: nil}
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

    # Derive formations from notification records when no live agents or UPM record exists.
    # Covers the case where formation agents sent notifications but never called /api/register.
    all_known_ids = MapSet.union(live_ids, MapSet.new(upm_only, & &1.id))

    notif_trees =
      AgentRegistry.get_notifications()
      |> Enum.filter(&(Map.get(&1, :formation_id) not in [nil, ""]))
      |> Enum.group_by(&Map.get(&1, :formation_id))
      |> Enum.reject(fn {fid, _} -> MapSet.member?(all_known_ids, fid) end)
      |> Enum.map(fn {formation_id, notifs} ->
        # Derive squadron names from notification titles (e.g. "Alpha: Squadron Complete")
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
            [] -> []
            names ->
              Enum.map(names, fn name ->
                sq_notifs = Enum.filter(notifs, &String.starts_with?(Map.get(&1, :title, ""), name <> ":"))
                status = if Enum.any?(sq_notifs, &(&1.type in ["success", "ok"])), do: "complete", else: "active"
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

  # --- Graph Push ---

  # Build D3 nodes and edges for all 5 hierarchy levels:
  # formation → squadron → swarm → cluster → agent
  defp push_formation_graph(socket, formations) do
    {nodes, edges} =
      Enum.reduce(formations, {[], []}, fn formation, {n, e} ->
        formation_node = %{
          id: formation.id,
          name: formation.name,
          level: "formation",
          status: formation_status(formation),
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
          {n2, e2} = Enum.reduce(squadron.agents, {n2, e2}, fn agent, {n3, e3} ->
            {[format_agent_node(agent) | n3], [%{source: sq_id, target: agent.id, edge_type: "hierarchy"} | e3]}
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

            # Direct swarm agents
            {n3, e3} = Enum.reduce(Map.get(swarm, :agents, []), {n3, e3}, fn agent, {n4, e4} ->
              {[format_agent_node(agent) | n4], [%{source: sw_id, target: agent.id, edge_type: "hierarchy"} | e4]}
            end)

            # Clusters
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
                {[format_agent_node(agent) | n5], [%{source: cl_id, target: agent.id, edge_type: "hierarchy"} | e5]}
              end)
            end)
          end)
        end)
      end)

    # Fetch raw agent data (with metadata) for pub/sub and data-export edge derivation.
    all_agents = AgentRegistry.list_agents()

    # Build a map: channel_name → publisher agent node id
    publisher_map =
      nodes
      |> Enum.filter(&(&1[:level] == "agent"))
      |> Enum.flat_map(fn node ->
        raw = Enum.find(all_agents, fn a -> a.id == node.id end)
        pubs = (raw && get_in(raw, [:metadata, :publishes])) || []
        Enum.map(pubs, fn ch -> {ch, node.id} end)
      end)
      |> Map.new()

    # Pub/sub edges: subscriber → publisher via shared channel name
    pubsub_edges =
      nodes
      |> Enum.filter(&(&1[:level] in ["agent", "squadron"]))
      |> Enum.flat_map(fn node ->
        raw = Enum.find(all_agents, fn a -> a.id == node.id end)
        subs = (raw && get_in(raw, [:metadata, :subscribes])) || []

        Enum.flat_map(subs, fn ch ->
          case Map.get(publisher_map, ch) do
            nil -> []
            pub_id -> [%{source: pub_id, target: node.id, edge_type: "pubsub"}]
          end
        end)
      end)

    # Data-export edges: exporter → importer matched by export label
    export_edges =
      nodes
      |> Enum.filter(&(&1[:level] in ["agent", "squadron"]))
      |> Enum.flat_map(fn node ->
        raw = Enum.find(all_agents, fn a -> a.id == node.id end)
        imports_list = (raw && get_in(raw, [:metadata, :imports])) || []

        Enum.flat_map(imports_list, fn imp ->
          exporter =
            Enum.find(nodes, fn n ->
              n_raw = Enum.find(all_agents, fn a -> a.id == n.id end)
              n_exports = (n_raw && get_in(n_raw, [:metadata, :exports])) || []
              imp in n_exports
            end)

          case exporter do
            nil -> []
            exp -> [%{source: exp.id, target: node.id, edge_type: "data_export"}]
          end
        end)
      end)

    # Aggregation edges: workers that publish to channels a squadron lead subscribes to
    aggregation_edges =
      nodes
      |> Enum.filter(&(&1[:level] == "squadron"))
      |> Enum.flat_map(fn sq_node ->
        raw = Enum.find(all_agents, fn a -> a.id == sq_node.id end)
        sq_subs = (raw && get_in(raw, [:metadata, :subscribes])) || []

        # Find agent nodes whose published channels overlap with the squadron's subscriptions
        nodes
        |> Enum.filter(&(&1[:level] == "agent"))
        |> Enum.flat_map(fn agent_node ->
          agent_raw = Enum.find(all_agents, fn a -> a.id == agent_node.id end)
          agent_pubs = (agent_raw && get_in(agent_raw, [:metadata, :publishes])) || []

          if Enum.any?(agent_pubs, &(&1 in sq_subs)) do
            [%{source: agent_node.id, target: sq_node.id, edge_type: "aggregation"}]
          else
            []
          end
        end)
      end)

    all_edges = edges ++ pubsub_edges ++ export_edges ++ aggregation_edges

    push_event(socket, "formation_data", %{nodes: Enum.reverse(nodes), edges: Enum.reverse(all_edges)})
  end

  # --- Private Helpers ---

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

  defp format_agent_node(agent) do
    %{
      id: agent.id,
      name: agent.name,
      level: "agent",
      status: agent.status,
      story_id: agent[:story_id],
      agent_type: agent[:agent_type],
      wave_number: agent[:wave_number],
      work_item_title: agent[:work_item_title],
      plane_issue_id: agent[:plane_issue_id],
      role: agent[:role]
    }
  end

  defp derive_status(agents) do
    cond do
      Enum.any?(agents, &(&1[:status] == "error")) -> "error"
      Enum.any?(agents, &(&1[:status] == "active")) -> "active"
      Enum.all?(agents, &(&1[:status] in ["pass", "complete", "done"])) and agents != [] -> "complete"
      true -> "idle"
    end
  end

  defp squadron_total_count(%{agents: direct, swarms: swarms}) do
    direct_count = length(direct)
    swarm_count = Enum.sum(Enum.map(swarms, &swarm_total_count/1))
    direct_count + swarm_count
  end
  defp squadron_total_count(%{agents: direct}), do: length(direct)

  defp swarm_total_count(%{agents: direct, clusters: clusters}) do
    length(direct) + Enum.sum(Enum.map(clusters, fn c -> length(c.agents) end))
  end
  defp swarm_total_count(%{agents: direct}), do: length(direct)

  defp formation_status(%{status: status}) when status in ["complete", "pass", "done"], do: "complete"
  defp formation_status(formation) do
    all_agents = all_formation_agents(formation)
    cond do
      Enum.any?(all_agents, &(&1.status == "error")) -> "error"
      Enum.any?(all_agents, &(&1.status == "active")) -> "active"
      Enum.all?(all_agents, &(&1.status in ["pass", "complete", "done"])) and all_agents != [] -> "complete"
      true -> formation[:status] || "idle"
    end
  end

  defp all_formation_agents(formation) do
    Enum.flat_map(formation.squadrons, fn sq ->
      direct = sq.agents
      swarm_agents = Enum.flat_map(Map.get(sq, :swarms, []), fn sw ->
        sw.agents ++ Enum.flat_map(Map.get(sw, :clusters, []), & &1.agents)
      end)
      direct ++ swarm_agents
    end)
  end

  defp level_badge("formation"), do: "bg-accent/20 text-accent"
  defp level_badge("squadron"), do: "bg-info/20 text-info"
  defp level_badge("swarm"), do: "bg-success/20 text-success"
  defp level_badge("cluster"), do: "bg-secondary/20 text-secondary"
  defp level_badge("agent"), do: "bg-primary/20 text-primary"
  defp level_badge(_), do: "bg-base-content/20 text-base-content/60"

  defp status_badge("active"), do: "badge-success"
  defp status_badge("complete"), do: "badge-info"
  defp status_badge("pass"), do: "badge-info"
  defp status_badge("done"), do: "badge-info"
  defp status_badge("error"), do: "badge-error"
  defp status_badge("idle"), do: "badge-ghost"
  defp status_badge(_), do: "badge-ghost"

  defp agent_dot("active"), do: "bg-success"
  defp agent_dot("complete"), do: "bg-info"
  defp agent_dot("pass"), do: "bg-info"
  defp agent_dot("done"), do: "bg-info"
  defp agent_dot("error"), do: "bg-error"
  defp agent_dot("idle"), do: "bg-base-content/30"
  defp agent_dot(_), do: "bg-base-content/20"

  defp agent_type_abbr("orchestrator"),  do: "[ORCH]"
  defp agent_type_abbr("squadron_lead"), do: "[LEAD]"
  defp agent_type_abbr("swarm_agent"),   do: "[SWM]"
  defp agent_type_abbr("cluster_agent"), do: "[CLU]"
  defp agent_type_abbr(_),               do: nil

  defp wave_percent(%{agents_in_wave: n, agents_complete: c}) when n > 0,
    do: round(c / n * 100)
  defp wave_percent(_), do: 0

  defp skill_count do
    try do
      map_size(Apm.SkillTracker.get_skill_catalog())
    catch
      :exit, _ -> 0
    end
  end

  # --- View Mode Helpers ---

  defp filter_agents_list(agents, query, role) do
    agents
    |> then(fn list ->
      if role == "" or is_nil(role) do
        list
      else
        Enum.filter(list, fn a ->
          (a[:formation_role] || a[:role] || "") == role
        end)
      end
    end)
    |> then(fn list ->
      if query == "" or is_nil(query) do
        list
      else
        q = String.downcase(query)

        Enum.filter(list, fn a ->
          String.contains?(String.downcase(a[:id] || ""), q) or
            String.contains?(String.downcase(a[:task_subject] || ""), q) or
            String.contains?(String.downcase(a[:role] || ""), q) or
            String.contains?(String.downcase(a[:work_item_title] || ""), q)
        end)
      end
    end)
  end

  defp list_group_by_role(agents) do
    role_order = ["orchestrator", "squadron_lead", "swarm_agent", "cluster_agent", "individual"]

    agents
    |> Enum.group_by(fn a -> a[:formation_role] || a[:role] || "individual" end)
    |> Enum.sort_by(fn {role, _} ->
      Enum.find_index(role_order, &(&1 == role)) || 99
    end)
  end

  defp cards_group_by_namespace(formations) do
    formations
    |> Enum.flat_map(fn f ->
      all_formation_agents(f)
      |> Enum.map(fn a ->
        project = a[:project] || "unknown"
        scope = f.id |> String.split("-") |> List.first() || "none"
        namespace = "#{project}/#{scope}"
        {namespace, a}
      end)
    end)
    |> Enum.group_by(fn {ns, _} -> ns end, fn {_, a} -> a end)
    |> Enum.sort_by(fn {k, _} -> k end)
  end

  defp cards_agent_border("active"), do: "border-success/40"
  defp cards_agent_border("complete"), do: "border-base-300"
  defp cards_agent_border("pass"), do: "border-base-300"
  defp cards_agent_border("done"), do: "border-base-300"
  defp cards_agent_border("error"), do: "border-error/40"
  defp cards_agent_border(_), do: "border-warning/30"

  defp cards_role_badge("orchestrator"), do: "badge-secondary"
  defp cards_role_badge("squadron_lead"), do: "badge-info"
  defp cards_role_badge("swarm_agent"), do: "badge-success"
  defp cards_role_badge("cluster_agent"), do: "badge-warning"
  defp cards_role_badge(_), do: "badge-ghost"

  defp list_role_color("orchestrator"), do: "text-secondary"
  defp list_role_color("squadron_lead"), do: "text-info"
  defp list_role_color("swarm_agent"), do: "text-success"
  defp list_role_color("cluster_agent"), do: "text-warning"
  defp list_role_color(_), do: "text-base-content/50"
end
