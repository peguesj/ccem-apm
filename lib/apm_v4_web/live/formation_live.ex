defmodule ApmV4Web.FormationLive do
  @moduledoc """
  LiveView for visualizing formation hierarchy (formation > squadron > swarm > cluster > agent)
  using a D3.js tree layout with real-time PubSub updates.
  """

  use ApmV4Web, :live_view

  alias ApmV4.AgentRegistry
  alias ApmV4.UpmStore

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:agents")
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:upm")
    end

    agents = AgentRegistry.list_agents()
    formations = build_formation_tree(agents)
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
      <%!-- Sidebar --%>
      <aside class="w-56 bg-base-200 border-r border-base-300 flex flex-col flex-shrink-0">
        <div class="p-4 border-b border-base-300">
          <h1 class="text-lg font-bold text-primary flex items-center gap-2">
            <span class="inline-block w-2 h-2 rounded-full bg-success animate-pulse"></span>
            CCEM APM v4
          </h1>
          <p class="text-xs text-base-content/50 mt-1">Agent Performance Monitor</p>
        </div>
        <nav class="flex-1 p-2 space-y-1">
          <.nav_item icon="hero-squares-2x2" label="Dashboard" active={false} href="/" />
          <.nav_item icon="hero-globe-alt" label="All Projects" active={false} href="/apm-all" />
          <.nav_item icon="hero-sparkles" label="Skills" active={false} href="/skills" badge={@active_skill_count} />
          <.nav_item icon="hero-arrow-path" label="Ralph" active={false} href="/ralph" />
          <.nav_item icon="hero-clock" label="Timeline" active={false} href="/timeline" />
          <.nav_item icon="hero-rectangle-group" label="Formations" active={true} href="/formation" />
          <.nav_item icon="hero-signal" label="Ports" active={false} href="/ports" />
          <.nav_item icon="hero-book-open" label="Docs" active={false} href="/docs" />
        </nav>
      </aside>

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
                  Formations appear when agents are registered with formation_id metadata.
                  Use /upm build or /formation deploy to create hierarchical agent structures.
                </p>
              </div>
            </div>
          </div>

          <%!-- Detail panel --%>
          <div class="w-72 border-l border-base-300 bg-base-200 flex flex-col flex-shrink-0 overflow-y-auto">
            <%!-- Selected node details --%>
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
            <div class="p-4">
              <div :if={@selected_node == nil} class="text-center text-base-content/30 py-8 text-xs">
                Click a node to inspect
              </div>
              <div :if={@selected_node} class="space-y-3">
                <div>
                  <div class={["inline-block px-2 py-0.5 rounded text-xs font-semibold mb-2", level_badge(@selected_node.level)]}>
                    {@selected_node.level}
                  </div>
                  <h3 class="text-sm font-bold">{@selected_node.name}</h3>
                </div>
                <div class="space-y-1 text-xs">
                  <div :if={@selected_node[:id]} class="flex justify-between">
                    <span class="text-base-content/50">ID</span>
                    <span class="font-mono text-[10px]">{@selected_node.id}</span>
                  </div>
                  <div :if={@selected_node[:status]} class="flex justify-between">
                    <span class="text-base-content/50">Status</span>
                    <span class={["badge badge-xs", status_badge(@selected_node.status)]}>{@selected_node.status}</span>
                  </div>
                  <div :if={@selected_node[:member_count]} class="flex justify-between">
                    <span class="text-base-content/50">Members</span>
                    <span>{@selected_node.member_count}</span>
                  </div>
                  <div :if={@selected_node[:story_id]} class="flex justify-between">
                    <span class="text-base-content/50">Story</span>
                    <span class="badge badge-xs badge-primary badge-outline font-mono">{@selected_node.story_id}</span>
                  </div>
                  <div :if={@selected_node[:wave]} class="flex justify-between">
                    <span class="text-base-content/50">Wave</span>
                    <span>{@selected_node.wave}</span>
                  </div>
                  <div :if={@selected_node[:role]} class="flex justify-between">
                    <span class="text-base-content/50">Role</span>
                    <span>{@selected_node.role}</span>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Formation list --%>
            <div class="p-4 border-t border-base-300">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3">
                Formation Tree
              </h3>
              <div class="space-y-2">
                <div :for={formation <- @formations} class="space-y-0.5">
                  <button
                    class="w-full text-left px-2 py-1 rounded text-xs font-semibold text-primary hover:bg-base-300"
                    phx-click="select_formation"
                    phx-value-id={formation.id}
                  >
                    {formation.name}
                    <span class="badge badge-xs badge-ghost ml-1">{formation.agent_count}</span>
                  </button>
                  <div :for={squadron <- formation.squadrons} class="pl-4">
                    <button
                      class="w-full text-left px-2 py-0.5 rounded text-[10px] text-info hover:bg-base-300"
                      phx-click="select_squadron"
                      phx-value-formation={formation.id}
                      phx-value-squadron={squadron.name}
                    >
                      {squadron.name}
                      <span class="text-base-content/30">{length(squadron.agents)}</span>
                    </button>
                    <div :for={agent <- squadron.agents} class="pl-4">
                      <button
                        class="w-full text-left px-2 py-0.5 rounded text-[10px] text-base-content/60 hover:bg-base-300 flex items-center gap-1"
                        phx-click="select_agent"
                        phx-value-id={agent.id}
                      >
                        <span class={["w-1.5 h-1.5 rounded-full", agent_dot(agent.status)]}></span>
                        {agent.name}
                      </button>
                    </div>
                  </div>
                </div>
                <div :if={@formations == []} class="text-xs text-base-content/30 py-4 text-center">
                  No formations registered
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Events ---

  @impl true
  def handle_event("refresh", _params, socket) do
    agents = AgentRegistry.list_agents()
    formations = build_formation_tree(agents)
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
      member_count: length(squadron.agents),
      status: squadron_status(squadron)
    }
    {:noreply, assign(socket, :selected_node, node)}
  end

  def handle_event("select_agent", %{"id" => id}, socket) do
    agent = AgentRegistry.get_agent(id)
    node = if agent, do: %{
      level: "agent",
      name: agent.name,
      id: agent.id,
      status: agent.status,
      story_id: agent[:story_id],
      wave: agent[:wave],
      role: agent[:role]
    }
    {:noreply, assign(socket, :selected_node, node)}
  end

  def handle_event("node_clicked", %{"id" => id, "level" => level}, socket) do
    case level do
      "formation" -> handle_event("select_formation", %{"id" => id}, socket)
      "agent" -> handle_event("select_agent", %{"id" => id}, socket)
      _ -> {:noreply, socket}
    end
  end

  # --- PubSub ---

  @impl true
  def handle_info({:agent_registered, _agent}, socket), do: refresh(socket)
  def handle_info({:agent_updated, _agent}, socket), do: refresh(socket)
  def handle_info({:agent_discovered, _, _}, socket), do: refresh(socket)
  def handle_info({:upm_session_registered, _}, socket), do: refresh(socket)
  def handle_info({:upm_agent_registered, _}, socket), do: refresh(socket)
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(socket) do
    agents = AgentRegistry.list_agents()
    formations = build_formation_tree(agents)
    {:noreply,
     socket
     |> assign(:agents, agents)
     |> assign(:formations, formations)
     |> push_formation_graph(formations)}
  end

  # --- Components ---

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :href, :string, required: true
  attr :badge, :any, default: nil

  defp nav_item(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "flex items-center gap-3 px-3 py-2 rounded text-sm transition-colors",
        @active && "bg-primary/10 text-primary font-medium",
        !@active && "text-base-content/60 hover:text-base-content hover:bg-base-300"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
      <span :if={@badge && @badge > 0} class="badge badge-xs badge-primary ml-auto">{@badge}</span>
    </a>
    """
  end

  # --- Helpers ---

  defp build_formation_tree(agents) do
    # Group agents by formation_id
    formation_groups =
      agents
      |> Enum.filter(&(&1[:formation_id] != nil))
      |> Enum.group_by(& &1[:formation_id])

    Enum.map(formation_groups, fn {formation_id, formation_agents} ->
      # Group by squadron within formation
      squadron_groups = Enum.group_by(formation_agents, &(&1[:squadron] || "default"))

      squadrons =
        Enum.map(squadron_groups, fn {squadron_name, sq_agents} ->
          %{
            name: squadron_name,
            agents: Enum.map(sq_agents, fn a ->
              %{id: a.id, name: a.name, status: a.status, role: a[:role],
                story_id: a[:story_id], wave: a[:wave], swarm: a[:swarm], cluster: a[:cluster]}
            end)
          }
        end)
        |> Enum.sort_by(& &1.name)

      %{
        id: formation_id,
        name: formation_id,
        agent_count: length(formation_agents),
        squadrons: squadrons
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp push_formation_graph(socket, formations) do
    # Build nodes and edges for D3
    nodes = []
    edges = []

    {nodes, edges} =
      Enum.reduce(formations, {nodes, edges}, fn formation, {n, e} ->
        formation_node = %{id: formation.id, name: formation.name, level: "formation",
                           status: formation_status(formation), count: formation.agent_count}
        n = [formation_node | n]

        Enum.reduce(formation.squadrons, {n, e}, fn squadron, {n2, e2} ->
          sq_id = "#{formation.id}/#{squadron.name}"
          sq_node = %{id: sq_id, name: squadron.name, level: "squadron",
                      status: squadron_status(squadron), count: length(squadron.agents)}
          e2 = [%{source: formation.id, target: sq_id} | e2]
          n2 = [sq_node | n2]

          Enum.reduce(squadron.agents, {n2, e2}, fn agent, {n3, e3} ->
            agent_node = %{id: agent.id, name: agent.name, level: "agent",
                           status: agent.status, story_id: agent[:story_id]}
            e3 = [%{source: sq_id, target: agent.id} | e3]
            {[agent_node | n3], e3}
          end)
        end)
      end)

    push_event(socket, "formation_data", %{nodes: Enum.reverse(nodes), edges: Enum.reverse(edges)})
  end

  defp formation_status(formation) do
    all_agents = Enum.flat_map(formation.squadrons, & &1.agents)
    cond do
      Enum.any?(all_agents, &(&1.status == "error")) -> "error"
      Enum.any?(all_agents, &(&1.status == "active")) -> "active"
      true -> "idle"
    end
  end

  defp squadron_status(squadron) do
    cond do
      Enum.any?(squadron.agents, &(&1.status == "error")) -> "error"
      Enum.any?(squadron.agents, &(&1.status == "active")) -> "active"
      true -> "idle"
    end
  end

  defp level_badge("formation"), do: "bg-accent/20 text-accent"
  defp level_badge("squadron"), do: "bg-info/20 text-info"
  defp level_badge("swarm"), do: "bg-warning/20 text-warning"
  defp level_badge("cluster"), do: "bg-secondary/20 text-secondary"
  defp level_badge("agent"), do: "bg-primary/20 text-primary"
  defp level_badge(_), do: "bg-base-content/20 text-base-content/60"

  defp status_badge("active"), do: "badge-success"
  defp status_badge("error"), do: "badge-error"
  defp status_badge("idle"), do: "badge-ghost"
  defp status_badge(_), do: "badge-ghost"

  defp agent_dot("active"), do: "bg-success"
  defp agent_dot("error"), do: "bg-error"
  defp agent_dot("idle"), do: "bg-base-content/30"
  defp agent_dot(_), do: "bg-base-content/20"

  defp wave_percent(%{agents_in_wave: n, agents_complete: c}) when n > 0,
    do: round(c / n * 100)
  defp wave_percent(_), do: 0

  defp skill_count do
    try do
      map_size(ApmV4.SkillTracker.get_skill_catalog())
    catch
      :exit, _ -> 0
    end
  end
end
