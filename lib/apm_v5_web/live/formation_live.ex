defmodule ApmV5Web.FormationLive do
  @moduledoc """
  LiveView for visualizing formation hierarchy (formation > squadron > swarm > cluster > agent)
  using a D3.js tree layout with real-time PubSub updates.

  All 5 hierarchy levels are rendered: swarm and cluster nodes are built from
  agent metadata fields `:swarm` and `:cluster`. Each agent node carries full
  metadata (agent_type, wave_number, work_item_title, plane_issue_id, parent_id).
  The Inspector panel shows a hierarchy breadcrumb and all available metadata.
  """

  use ApmV5Web, :live_view


  alias ApmV5.AgentRegistry
  alias ApmV5.UpmStore

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:agents")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:upm")
      # US-018: EventBus subscriptions for AG-UI formation events
      ApmV5.AgUi.EventBus.subscribe("lifecycle:*")
    end

    agents = AgentRegistry.list_agents()
    upm_formations = try do UpmStore.list_formations() catch :exit, _ -> [] end
    formations = build_formation_tree(agents, upm_formations)
    active_formation = try do UpmStore.get_active_formation() catch :exit, _ -> nil end

    socket =
      socket
      |> assign(:page_title, "Formations")
      |> assign(:agents, agents)
      |> assign(:formations, formations)
      |> assign(:active_formation, active_formation)
      |> assign(:selected_node, nil)
      |> assign(:wave_progress, %{current_wave: 0, total_waves: 0, agents_in_wave: 0, agents_complete: 0})
      |> assign(:active_skill_count, skill_count())
      |> push_formation_graph(formations)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <.sidebar_nav current_path="/formation" skill_count={@active_skill_count} />

      <%!-- Main content --%>
      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Top bar --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Formation Hierarchy</h2>
            <div class="badge badge-sm badge-ghost">
              {length(@formations)} formations
            </div>
            <div class="badge badge-sm badge-ghost">
              {length(@agents)} agents
            </div>
          </div>
          <div class="flex items-center gap-2">
            <button phx-click="refresh" class="btn btn-ghost btn-xs">
              <.icon name="hero-arrow-path" class="size-3" /> Refresh
            </button>
          </div>
        </header>

        <%!-- Body --%>
        <div class="flex-1 flex overflow-hidden">
          <%!-- Graph area --%>
          <div class="flex-1 overflow-hidden relative">
            <div
              id="formation-graph"
              class="w-full h-full"
              style="background: #151b28;"
              phx-hook="FormationGraph"
              phx-update="ignore"
            >
            </div>

            <%!-- Empty state --%>
            <div :if={@formations == []} class="absolute inset-0 flex items-center justify-center">
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
    </div>
    <.wizard page="formation" />
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

  # --- Events ---

  @impl true
  def handle_event("refresh", _params, socket) do
    agents = AgentRegistry.list_agents()
    upm_formations = try do UpmStore.list_formations() catch :exit, _ -> [] end
    formations = build_formation_tree(agents, upm_formations)
    {:noreply,
     socket
     |> assign(:agents, agents)
     |> assign(:formations, formations)
     |> push_formation_graph(formations)}
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
    {:noreply,
     socket
     |> assign(:agents, agents)
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
      |> Enum.filter(&(&1[:formation_id] != nil))
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

    (live_formations ++ upm_trees)
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
          e2 = [%{source: formation.id, target: sq_id} | e2]
          n2 = [sq_node | n2]

          # Direct squadron agents
          {n2, e2} = Enum.reduce(squadron.agents, {n2, e2}, fn agent, {n3, e3} ->
            {[format_agent_node(agent) | n3], [%{source: sq_id, target: agent.id} | e3]}
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
            e3 = [%{source: sq_id, target: sw_id} | e3]
            n3 = [sw_node | n3]

            # Direct swarm agents
            {n3, e3} = Enum.reduce(Map.get(swarm, :agents, []), {n3, e3}, fn agent, {n4, e4} ->
              {[format_agent_node(agent) | n4], [%{source: sw_id, target: agent.id} | e4]}
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
              e4 = [%{source: sw_id, target: cl_id} | e4]
              n4 = [cl_node | n4]

              Enum.reduce(cluster.agents, {n4, e4}, fn agent, {n5, e5} ->
                {[format_agent_node(agent) | n5], [%{source: cl_id, target: agent.id} | e5]}
              end)
            end)
          end)
        end)
      end)

    push_event(socket, "formation_data", %{nodes: Enum.reverse(nodes), edges: Enum.reverse(edges)})
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
      map_size(ApmV5.SkillTracker.get_skill_catalog())
    catch
      :exit, _ -> 0
    end
  end
end
