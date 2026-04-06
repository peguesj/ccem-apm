defmodule ApmV5Web.ArchitectureLive do
  @moduledoc """
  Architecture visualization LiveView.

  Displays registered architecture types with their hierarchical graph
  using Railway-inspired glassmorphic aesthetics. Default: Diligent.
  """

  use ApmV5Web, :live_view

  alias ApmV5.Architectures.ArchitectureStore
  alias ApmV5.AgentRegistry

  @refresh_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:architectures")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:agents")
      :timer.send_interval(@refresh_ms, self(), :refresh)
    end

    architectures = safe_list_architectures()
    active_arch = List.first(architectures)
    active_name = if active_arch, do: active_arch.name, else: "diligent"

    socket =
      socket
      |> assign(:page_title, "Architecture")
      |> assign(:architectures, architectures)
      |> assign(:active_architecture, active_name)
      |> assign(:tree, nil)
      |> assign(:graph_config, nil)
      |> assign(:view_mode, :graph)
      |> build_and_push_tree()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, build_and_push_tree(socket)}
  end

  def handle_info({:tree_built, _name, _tree}, socket) do
    {:noreply, build_and_push_tree(socket)}
  end

  def handle_info({:agent_registered, _}, socket) do
    {:noreply, build_and_push_tree(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("switch_architecture", %{"name" => name}, socket) do
    socket =
      socket
      |> assign(:active_architecture, name)
      |> build_and_push_tree()

    {:noreply, socket}
  end

  def handle_event("switch_view", %{"mode" => mode}, socket) do
    mode_atom = String.to_existing_atom(mode)
    {:noreply, assign(socket, :view_mode, mode_atom)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <.sidebar_nav current_path="/architecture" />

      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0 relative z-10">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Architecture</h2>

            <%!-- Architecture selector --%>
            <div :if={length(@architectures) > 0} class="dropdown dropdown-bottom">
              <div tabindex="0" role="button" class="btn btn-ghost btn-xs gap-1">
                <.icon name="hero-cube-transparent" class="size-3" />
                {@active_architecture}
                <.icon name="hero-chevron-down" class="size-3" />
              </div>
              <ul tabindex="0" class="dropdown-content z-50 menu menu-xs p-1 bg-base-200 border border-base-300 rounded-box shadow-lg w-48">
                <li :for={arch <- @architectures}>
                  <button
                    phx-click="switch_architecture"
                    phx-value-name={arch.name}
                    class={@active_architecture == arch.name && "active"}
                  >
                    {arch.name}
                    <span class="badge badge-xs badge-ghost">{length(arch.levels)} levels</span>
                  </button>
                </li>
              </ul>
            </div>

            <div :if={@tree} class="badge badge-sm badge-ghost">
              {@tree["agent_count"] || 0} agents
            </div>
          </div>

          <div class="flex items-center gap-2">
            <%!-- View mode toggle --%>
            <div class="join">
              <button
                phx-click="switch_view"
                phx-value-mode="graph"
                class={"join-item btn btn-xs #{if @view_mode == :graph, do: "btn-primary", else: "btn-ghost"}"}
              >
                Graph
              </button>
              <button
                phx-click="switch_view"
                phx-value-mode="list"
                class={"join-item btn btn-xs #{if @view_mode == :list, do: "btn-primary", else: "btn-ghost"}"}
              >
                List
              </button>
              <button
                phx-click="switch_view"
                phx-value-mode="cards"
                class={"join-item btn btn-xs #{if @view_mode == :cards, do: "btn-primary", else: "btn-ghost"}"}
              >
                Cards
              </button>
            </div>
          </div>
        </header>

        <main class="flex-1 overflow-hidden">
          <%!-- Graph view --%>
          <div :if={@view_mode == :graph} class="h-full">
            <div
              id="architecture-graph"
              phx-hook="ArchitectureGraph"
              phx-update="ignore"
              class="w-full h-full"
              style="background: #0f172a;"
            >
            </div>
          </div>

          <%!-- List view --%>
          <div :if={@view_mode == :list} class="h-full overflow-y-auto p-4">
            <div :if={@tree} class="max-w-4xl mx-auto">
              <.tree_node node={@tree} depth={0} />
            </div>
            <div :if={is_nil(@tree)} class="text-center text-base-content/30 py-12">
              No architecture tree built yet. Register agents to populate.
            </div>
          </div>

          <%!-- Cards view --%>
          <div :if={@view_mode == :cards} class="h-full overflow-y-auto p-4">
            <div :if={@tree} class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4 max-w-6xl mx-auto">
              <div
                :for={child <- @tree["children"] || []}
                class="card bg-base-200 border border-base-300 hover:border-primary/30 transition-colors"
              >
                <div class="card-body p-4">
                  <div class="flex items-center gap-2 mb-2">
                    <span class={"w-3 h-3 rounded-full #{level_color_class(child["level"])}"} />
                    <h3 class="font-semibold text-sm">{child["name"]}</h3>
                    <span class="badge badge-xs badge-ghost ml-auto">{child["level"]}</span>
                  </div>
                  <div class="text-xs text-base-content/50 space-y-1">
                    <div>Agents: {child["agent_count"]}</div>
                    <div>Status: <span class={status_text_class(child["status"])}>{child["status"]}</span></div>
                    <div :if={child["children"]}>
                      Children: {length(child["children"])}
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </main>
      </div>
    </div>
    """
  end

  # Recursive tree node component for list view
  defp tree_node(assigns) do
    ~H"""
    <div class={"ml-#{min(@depth * 4, 16)} border-l border-base-300 pl-3 py-1"}>
      <div class="flex items-center gap-2 py-1 hover:bg-base-200 rounded px-2 -ml-2">
        <span class={"w-2.5 h-2.5 rounded-full flex-shrink-0 #{level_color_class(@node["level"])}"} />
        <span class="font-mono text-xs text-base-content/70">{@node["level"]}</span>
        <span class="text-sm font-medium">{@node["name"]}</span>
        <span :if={@node["agent_count"] > 0} class="badge badge-xs badge-ghost">
          {@node["agent_count"]} agents
        </span>
        <span class={["badge badge-xs", status_badge_class(@node["status"])]}>
          {@node["status"]}
        </span>
      </div>
      <div :for={child <- @node["children"] || []}>
        <.tree_node node={child} depth={@depth + 1} />
      </div>
    </div>
    """
  end

  # --- Private ---

  defp build_and_push_tree(socket) do
    arch_name = socket.assigns.active_architecture
    agents = safe_list_agents()

    case ArchitectureStore.build_tree(arch_name, agents) do
      {:ok, tree} ->
        graph_config = ArchitectureStore.graph_config(arch_name)

        socket
        |> assign(:tree, tree)
        |> assign(:graph_config, graph_config)
        |> push_event("architecture:data", %{tree: tree, config: graph_config})

      {:error, _reason} ->
        socket
    end
  end

  defp safe_list_agents do
    try do
      AgentRegistry.list_agents()
    catch
      :exit, _ -> []
    end
  end

  defp safe_list_architectures do
    try do
      ArchitectureStore.list_architectures()
    catch
      :exit, _ -> []
    end
  end

  defp level_color_class("fleet"), do: "bg-fuchsia-400"
  defp level_color_class("formation"), do: "bg-blue-500"
  defp level_color_class("squadron"), do: "bg-cyan-500"
  defp level_color_class("swarm"), do: "bg-green-500"
  defp level_color_class("agent"), do: "bg-orange-500"
  defp level_color_class(_), do: "bg-gray-500"

  defp status_badge_class("active"), do: "badge-success"
  defp status_badge_class("working"), do: "badge-success"
  defp status_badge_class("error"), do: "badge-error"
  defp status_badge_class("idle"), do: "badge-ghost"
  defp status_badge_class("completed"), do: "badge-info"
  defp status_badge_class(_), do: "badge-ghost"

  defp status_text_class("active"), do: "text-success"
  defp status_text_class("error"), do: "text-error"
  defp status_text_class(_), do: "text-base-content/50"
end
