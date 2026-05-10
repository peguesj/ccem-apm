defmodule ApmV5Web.SessionManagerLive do
  @moduledoc """
  LiveView for the Session Manager at /sessions and /sessions/:id.

  Left panel: session list with active/inactive badges and pulse animation.
  Right panel: 5 tabs — Overview, Claude Config, Agents, Ports, Plugins.
  Auto-refreshes every 10 seconds, subscribes to "apm:sessions" PubSub.
  """

  use ApmV5Web, :live_view

  alias ApmV5.SessionManager
  alias ApmV5.NamespaceResolver
  import ApmV5Web.Components.SidebarNav

  @refresh_ms 10_000

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:sessions")
      # Immediate refresh after 1s to catch sessions that loaded after initial mount
      Process.send_after(self(), :refresh, 1_000)
    end

    sessions = SessionManager.list_sessions()
    selected_id = params["id"]

    selected =
      case selected_id do
        nil -> List.first(sessions)
        id -> SessionManager.get_session_with_context(id) || List.first(sessions)
      end

    {:ok,
     socket
     |> assign(
       page_title: "Sessions",
       sessions: sessions,
       selected: selected,
       active_tab: "overview",
       current_path: "/sessions",
       notification_count: 0,
       skill_count: 0,
       filter_active_only: false,
       filter_search: "",
       group_by: "none",
       hidden_sessions: MapSet.new(),
       show_hidden: false
     )
     |> assign_sidebar_nav_data()}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    selected = SessionManager.get_session_with_context(id)
    {:noreply, assign(socket, selected: selected)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    sessions = SessionManager.list_sessions()

    selected =
      case socket.assigns.selected do
        nil -> List.first(sessions)
        s -> SessionManager.get_session_with_context(to_string(s[:session_id] || ""))
      end

    {:noreply, assign(socket, sessions: sessions, selected: selected)}
  end

  def handle_info({:sessions_updated, sessions}, socket) do
    selected =
      case socket.assigns.selected do
        nil -> List.first(sessions)
        s ->
          sid = to_string(s[:session_id] || "")
          Enum.find(sessions, List.first(sessions), &(to_string(&1[:session_id]) == sid))
      end

    {:noreply, assign(socket, sessions: sessions, selected: selected)}
  end

  @impl true
  def handle_event("select_session", %{"id" => id}, socket) do
    selected = SessionManager.get_session_with_context(id)
    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  def handle_event("refresh", _params, socket) do
    SessionManager.refresh()
    sessions = SessionManager.list_sessions()
    {:noreply, assign(socket, sessions: sessions)}
  end

  def handle_event("filter_search", %{"search" => term}, socket) do
    {:noreply, assign(socket, filter_search: term)}
  end

  def handle_event("toggle_active_filter", _params, socket) do
    {:noreply, assign(socket, filter_active_only: !socket.assigns.filter_active_only)}
  end

  def handle_event("set_group_by", %{"group_by" => group_by}, socket) do
    {:noreply, assign(socket, group_by: group_by)}
  end

  def handle_event("toggle_session_visibility", %{"id" => id}, socket) do
    hidden = socket.assigns.hidden_sessions

    updated =
      if MapSet.member?(hidden, id),
        do: MapSet.delete(hidden, id),
        else: MapSet.put(hidden, id)

    {:noreply, assign(socket, hidden_sessions: updated)}
  end

  def handle_event("toggle_show_hidden", _params, socket) do
    {:noreply, assign(socket, show_hidden: !socket.assigns.show_hidden)}
  end

  @impl true
  def render(assigns) do
    grouped = prepare_session_list(assigns)
    hidden_count = MapSet.size(assigns.hidden_sessions)
    assigns = assign(assigns, grouped: grouped, hidden_count: hidden_count)

    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav
        current_path={@current_path}
        notification_count={@notification_count}
        skill_count={@skill_count}
        />
      </:sidebar>
      <:main>

      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0 relative z-10">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Sessions</h2>
            <div class="badge badge-sm badge-ghost">{length(@sessions)} total</div>
          </div>
          <div class="flex items-center gap-2">
            <span class="text-xs text-base-content/40">Auto-refresh 10s</span>
            <button phx-click="refresh" class="btn btn-ghost btn-xs">
              <.icon name="hero-arrow-path" class="size-3.5" />
            </button>
          </div>
        </header>

        <div class="flex flex-1 overflow-hidden">
          <!-- Session List Panel -->
          <div class="w-80 bg-base-200 border-r border-base-300 flex flex-col overflow-hidden">

          <!-- Filter Bar -->
          <div class="p-2 border-b border-base-300 space-y-2">
            <form phx-change="filter_search" class="relative">
              <input
                type="text"
                name="search"
                value={@filter_search}
                placeholder="Search sessions..."
                phx-debounce="200"
                class="input input-xs input-bordered w-full pl-7 text-xs"
              />
              <.icon name="hero-magnifying-glass" class="size-3 absolute left-2 top-1/2 -translate-y-1/2 text-base-content/40" />
            </form>
            <div class="flex items-center gap-2">
              <select
                name="group_by"
                phx-change="set_group_by"
                class="select select-xs select-bordered flex-1 text-xs"
              >
                <option value="none" selected={@group_by == "none"}>No grouping</option>
                <option value="date" selected={@group_by == "date"}>By date</option>
                <option value="project" selected={@group_by == "project"}>By project</option>
                <option value="context" selected={@group_by == "context"}>By init context</option>
                <option value="working_context" selected={@group_by == "working_context"}>By branch/worktree</option>
              </select>
              <label class="flex items-center gap-1 cursor-pointer" title="Active only">
                <input
                  type="checkbox"
                  checked={@filter_active_only}
                  phx-click="toggle_active_filter"
                  class="checkbox checkbox-xs checkbox-primary"
                />
                <span class="text-[10px] text-base-content/60">Active</span>
              </label>
            </div>
            <%= if @hidden_count > 0 do %>
              <div class="flex items-center gap-1">
                <label class="flex items-center gap-1 cursor-pointer">
                  <input
                    type="checkbox"
                    checked={@show_hidden}
                    phx-click="toggle_show_hidden"
                    class="checkbox checkbox-xs"
                  />
                  <span class="text-[10px] text-base-content/50">
                    Show hidden (<%= @hidden_count %>)
                  </span>
                </label>
              </div>
            <% end %>
          </div>

          <!-- Session List -->
          <div class="flex-1 overflow-y-auto p-2 space-y-1">
            <%= for {group_name, group_sessions} <- @grouped do %>
              <%= if @group_by != "none" do %>
                <div class="collapse collapse-arrow bg-base-300/50 rounded-lg mb-1">
                  <input type="checkbox" checked />
                  <div class="collapse-title text-xs font-semibold py-2 min-h-0">
                    <%= group_name %>
                    <span class="badge badge-xs badge-neutral ml-1"><%= length(group_sessions) %></span>
                  </div>
                  <div class="collapse-content px-1 pb-1 space-y-1">
                    <%= for session <- group_sessions do %>
                      <.session_row
                        session={session}
                        selected={@selected}
                        hidden_sessions={@hidden_sessions}
                      />
                    <% end %>
                  </div>
                </div>
              <% else %>
                <%= for session <- group_sessions do %>
                  <.session_row
                    session={session}
                    selected={@selected}
                    hidden_sessions={@hidden_sessions}
                  />
                <% end %>
              <% end %>
            <% end %>
            <%= if Enum.all?(@grouped, fn {_, sessions} -> Enum.empty?(sessions) end) do %>
              <div class="text-center text-base-content/40 text-xs py-8">No sessions match filters</div>
            <% end %>
          </div>
        </div>

        <!-- Detail Panel -->
        <div class="flex-1 flex flex-col overflow-hidden">
          <%= if @selected do %>
            <% session = @selected %>
            <% sid = to_string(session[:session_id] || "") %>
            <div class="p-4 border-b border-base-300 bg-base-100">
              <div class="flex items-start justify-between">
                <div>
                  <h1 class="text-lg font-bold">
                    <%= session[:project_name] || "Unknown Project" %>
                  </h1>
                  <div class="text-xs font-mono text-base-content/40 mt-0.5"><%= sid %></div>
                  <div class="text-xs text-base-content/50 mt-0.5">
                    <%= session[:project_root] %>
                  </div>
                </div>
                <div class="flex items-center gap-2">
                  <%= if to_string(session[:status]) == "active" do %>
                    <span class="badge badge-success">active</span>
                  <% else %>
                    <span class="badge badge-ghost">inactive</span>
                  <% end %>
                </div>
              </div>

              <!-- Tabs -->
              <div class="tabs tabs-bordered mt-4">
                <%= for {tab_id, tab_label} <- [{"overview", "Overview"}, {"claude_config", "Claude Config"}, {"agents", "Agents"}, {"ports", "Ports"}, {"plugins", "Plugins"}] do %>
                  <button
                    phx-click="set_tab"
                    phx-value-tab={tab_id}
                    class={"tab text-xs #{if @active_tab == tab_id, do: "tab-active font-semibold"}"}
                  >
                    <%= tab_label %>
                    <%= if tab_id == "agents" && (session[:agent_count] || 0) > 0 do %>
                      <span class="badge badge-xs badge-primary ml-1"><%= session[:agent_count] %></span>
                    <% end %>
                  </button>
                <% end %>
              </div>
            </div>

            <div class="flex-1 overflow-y-auto p-4">
              <%= case @active_tab do %>
                <% "overview" -> %>
                  <.tab_overview session={session} />
                <% "claude_config" -> %>
                  <.tab_claude_config session={session} />
                <% "agents" -> %>
                  <.tab_agents session={session} />
                <% "ports" -> %>
                  <.tab_ports session={session} />
                <% "plugins" -> %>
                  <.tab_plugins session={session} />
                <% _ -> %>
                  <div class="text-base-content/40 text-sm">Select a tab above.</div>
              <% end %>
            </div>
          <% else %>
            <div class="flex-1 flex items-center justify-center text-base-content/30">
              <div class="text-center">
                <.icon name="hero-computer-desktop" class="size-12 mb-3 mx-auto" />
                <div class="text-sm">Select a session to view details</div>
              </div>
            </div>
          <% end %>
        </div>
      </div>
      </div>
      </:main>
    </.page_layout>
    """
  end

  # ── Tab components ───────────────────────────────────────────────────────────

  defp tab_overview(assigns) do
    session = assigns.session
    is_active = to_string(session[:status] || "") == "active"
    freshness = format_freshness(session[:enriched_at])

    assigns =
      assigns
      |> assign(:is_active, is_active)
      |> assign(:freshness, freshness)
      |> assign(:topology_payload, Jason.encode!(build_topology_payload(session)))

    ~H"""
    <!-- Hero card with descriptive title + active badge + freshness -->
    <div class="card bg-gradient-to-br from-base-200 to-base-300 p-4 mb-4 border border-base-300">
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0">
          <div class="flex items-center gap-2 mb-1">
            <h3 class="text-base font-bold text-base-content truncate">
              <%= @session[:project_name] || "Unknown Project" %>
            </h3>
            <%= if @is_active do %>
              <span class="badge badge-sm badge-success gap-1">
                <span class="w-1.5 h-1.5 rounded-full bg-success-content animate-pulse"></span>
                live
              </span>
            <% else %>
              <span class="badge badge-sm badge-ghost">inactive</span>
            <% end %>
          </div>
          <div class="text-xs text-base-content/50">
            Session scope · <%= @session[:git_branch] || "no branch" %>
          </div>
        </div>
        <div class="text-right flex-shrink-0">
          <div class="text-[10px] uppercase tracking-wide text-base-content/40">Enriched</div>
          <div class="text-xs text-base-content/70"><%= @freshness %></div>
        </div>
      </div>
    </div>

    <!-- Clickable stat cards — each pushes set_tab for deep-dive -->
    <div class="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4">
      <button phx-click="set_tab" phx-value-tab="agents" class="card bg-base-200 p-3 text-left hover:bg-base-300 transition-colors">
        <div class="flex items-center gap-2 mb-1">
          <.icon name="hero-user-group" class="size-3.5 text-base-content/40" />
          <span class="text-xs text-base-content/50">Agents</span>
        </div>
        <div class="text-2xl font-bold text-base-content"><%= @session[:agent_count] || 0 %></div>
      </button>
      <button phx-click="set_tab" phx-value-tab="ports" class="card bg-base-200 p-3 text-left hover:bg-base-300 transition-colors">
        <div class="flex items-center gap-2 mb-1">
          <.icon name="hero-signal" class="size-3.5 text-base-content/40" />
          <span class="text-xs text-base-content/50">Ports</span>
        </div>
        <div class="text-2xl font-bold text-base-content"><%= @session[:port_count] || 0 %></div>
      </button>
      <button phx-click="set_tab" phx-value-tab="plugins" class="card bg-base-200 p-3 text-left hover:bg-base-300 transition-colors">
        <div class="flex items-center gap-2 mb-1">
          <.icon name="hero-puzzle-piece" class="size-3.5 text-base-content/40" />
          <span class="text-xs text-base-content/50">Plugins</span>
        </div>
        <div class="text-2xl font-bold text-base-content"><%= @session[:plugin_count] || 0 %></div>
      </button>
      <button phx-click="set_tab" phx-value-tab="claude_config" class="card bg-base-200 p-3 text-left hover:bg-base-300 transition-colors">
        <div class="flex items-center gap-2 mb-1">
          <.icon name="hero-sparkles" class="size-3.5 text-base-content/40" />
          <span class="text-xs text-base-content/50">Skills</span>
        </div>
        <div class="text-2xl font-bold text-base-content">
          <%= get_in(@session, [:claude_config, :skill_count]) || 0 %>
        </div>
      </button>
    </div>

    <!-- Topology diagram -->
    <.collapsible title="Session Topology" open={true}>
      <div
        id={"overview-topology-diagram-#{to_string(@session[:session_id] || "none")}"}
        phx-hook="SessionDiagram"
        phx-update="ignore"
        data-diagram-type="topology"
        data-diagram-payload={@topology_payload}
        class="w-full min-h-[320px]"
      ></div>
    </.collapsible>

    <.collapsible title="Session Metadata" open={false}>
      <div class="grid grid-cols-1 md:grid-cols-2 gap-x-6 gap-y-2">
        <.info_row label="Session ID" value={to_string(@session[:session_id] || "")} mono />
        <.info_row label="Project" value={to_string(@session[:project_name] || "")} />
        <.info_row label="Root" value={to_string(@session[:project_root] || "")} mono />
        <.info_row label="Started" value={to_string(@session[:start_time] || "")} />
        <.info_row label="JSONL" value={to_string(@session[:session_jsonl] || "")} mono />
        <%= if @session[:tasks_dir] && @session[:tasks_dir] != "" do %>
          <.info_row label="Tasks Dir" value={to_string(@session[:tasks_dir])} mono />
        <% end %>
        <%= if @session[:enriched_at] do %>
          <.info_row label="Enriched At" value={to_string(@session[:enriched_at])} />
        <% end %>
      </div>
    </.collapsible>
    """
  end

  defp tab_claude_config(assigns) do
    config = assigns.session[:claude_config] || %{}

    assigns =
      assigns
      |> assign(:config, config)
      |> assign(:hook_payload, Jason.encode!(build_hook_lifecycle_payload(config)))

    ~H"""
    <div class="grid grid-cols-3 gap-3 mb-6">
      <.stat_card label="Memory Files" value={@config[:memory_count] || 0} icon="hero-document-text" />
      <.stat_card label="Agents" value={@config[:agent_count] || 0} icon="hero-user-group" />
      <.stat_card label="Skills" value={@config[:skill_count] || 0} icon="hero-sparkles" />
      <.stat_card label="Hooks" value={@config[:hook_count] || 0} icon="hero-bolt" />
      <div class="col-span-2 card bg-base-200 p-3">
        <div class="text-xs text-base-content/50 mb-1">CLAUDE.md</div>
        <div class={"text-sm font-semibold #{if @config[:has_claude_md], do: "text-success", else: "text-base-content/30"}"}>
          <%= if @config[:has_claude_md], do: "Present", else: "Not found" %>
        </div>
      </div>
    </div>

    <%= if @config[:claude_md_preview] && @config[:claude_md_preview] != "" do %>
      <.collapsible title="CLAUDE.md Preview" open={true}>
        <div class="doc-content prose prose-sm prose-invert max-w-none text-base-content/80">
          <%= render_markdown(@config[:claude_md_preview]) %>
        </div>
        <%= if String.length(@config[:claude_md_preview] || "") >= 498 do %>
          <div class="text-xs text-base-content/30 mt-2">... (truncated — full file not loaded)</div>
        <% end %>
      </.collapsible>
    <% end %>

    <.collapsible title="Hook Lifecycle" open={false}>
      <div class="text-xs text-base-content/50 mb-2">
        <%= @config[:hook_count] || 0 %> hook script<%= if (@config[:hook_count] || 0) == 1, do: "", else: "s" %>
        registered in <code class="text-[11px]">~/Developer/ccem/apm/hooks/</code>
      </div>
      <div
        id={"claude-config-hook-lifecycle-#{to_string(@session[:session_id] || "none")}"}
        phx-hook="SessionDiagram"
        phx-update="ignore"
        data-diagram-type="hook-lifecycle"
        data-diagram-payload={@hook_payload}
        class="w-full min-h-[260px]"
      ></div>
    </.collapsible>
    """
  end

  defp tab_agents(assigns) do
    agents = assigns.session[:agents] || []

    waves =
      agents
      |> Enum.group_by(fn a -> Map.get(a, :wave, Map.get(a, :wave_number, 0)) || 0 end)
      |> Enum.sort_by(fn {wave, _} -> wave end)

    assigns =
      assigns
      |> assign(:agents, agents)
      |> assign(:waves, waves)
      |> assign(:formation_payload, Jason.encode!(build_formation_tree_payload(agents)))

    ~H"""
    <%= if Enum.empty?(@agents) do %>
      <div class="text-center text-base-content/40 text-sm py-8">No agents registered for this session</div>
    <% else %>
      <!-- Grouped by wave -->
      <%= for {{wave, wave_agents}, idx} <- Enum.with_index(@waves) do %>
        <.collapsible title={"Wave #{wave} · #{length(wave_agents)} agent#{if length(wave_agents) == 1, do: "", else: "s"}"} open={idx == 0}>
          <div class="space-y-2">
            <%= for agent <- wave_agents do %>
              <% agent_id = to_string(Map.get(agent, :agent_id, "unknown")) %>
              <% display_label =
                Map.get(agent, :display_name) ||
                  NamespaceResolver.agent_label(agent_id,
                    role: Map.get(agent, :role),
                    task_subject: Map.get(agent, :task_subject),
                    formation_id: Map.get(agent, :formation_id),
                    project: Map.get(agent, :project)
                  ) %>
              <div class="card bg-base-100 p-3 border border-base-300">
                <div class="flex items-center justify-between gap-2">
                  <span class="tooltip tooltip-left min-w-0" data-tip={agent_id}>
                    <div class="text-sm font-semibold truncate"><%= display_label %></div>
                  </span>
                  <span class={"badge badge-xs flex-shrink-0 #{status_badge_class(to_string(Map.get(agent, :status, "")))}"}>
                    <%= Map.get(agent, :status, "unknown") %>
                  </span>
                </div>
                <div class="text-xs text-base-content/50 mt-1">
                  Role: <%= Map.get(agent, :role, "—") %>
                  <%= if Map.get(agent, :formation_role) do %>
                    · <%= Map.get(agent, :formation_role) %>
                  <% end %>
                </div>
                <%= if Map.get(agent, :task_subject) do %>
                  <div class="text-xs text-base-content/60 mt-0.5 truncate"><%= Map.get(agent, :task_subject) %></div>
                <% end %>
              </div>
            <% end %>
          </div>
        </.collapsible>
      <% end %>

      <!-- Formation tree diagram -->
      <.collapsible title="Formation Tree" open={false}>
        <div
          id={"agents-formation-tree-#{to_string(@session[:session_id] || "none")}"}
          phx-hook="SessionDiagram"
          phx-update="ignore"
          data-diagram-type="formation-tree"
          data-diagram-payload={@formation_payload}
          class="w-full min-h-[320px]"
        ></div>
      </.collapsible>
    <% end %>
    """
  end

  defp tab_ports(assigns) do
    ports = assigns.session[:ports] || []
    {active_ports, free_ports} = Enum.split_with(ports, fn p -> Map.get(p, :in_use, false) end)

    assigns =
      assigns
      |> assign(:active_ports, active_ports)
      |> assign(:free_ports, free_ports)

    ~H"""
    <%= if Enum.empty?(@active_ports) and Enum.empty?(@free_ports) do %>
      <div class="text-center text-base-content/40 text-sm py-8">No ports bound to this project</div>
    <% else %>
      <%= if not Enum.empty?(@active_ports) do %>
        <.collapsible title={"Active · #{length(@active_ports)}"} open={true}>
          <div class="space-y-2">
            <%= for port <- @active_ports do %>
              <% port_num = Map.get(port, :port, "?") %>
              <% cmd = Map.get(port, :command) || Map.get(port, :process) || Map.get(port, :name, "") %>
              <div class="card bg-base-100 p-3 border border-base-300">
                <div class="flex flex-row items-center gap-4">
                  <div class="font-mono text-lg font-bold text-primary"><%= port_num %></div>
                  <div class="flex-1 min-w-0">
                    <span class="tooltip tooltip-left block" data-tip={to_string(cmd)}>
                      <div class="text-xs font-semibold truncate"><%= Map.get(port, :name, "unknown") %></div>
                    </span>
                    <div class="text-xs text-base-content/50 truncate"><%= Map.get(port, :project, "") %></div>
                  </div>
                  <span class="badge badge-xs badge-success flex-shrink-0">in use</span>
                </div>
                <%= if Map.get(port, :session_id) do %>
                  <div class="text-xs opacity-60 mt-1 font-mono truncate">
                    session: <%= Map.get(port, :session_id) %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </.collapsible>
      <% end %>

      <%= if not Enum.empty?(@free_ports) do %>
        <.collapsible title={"Free · #{length(@free_ports)}"} open={false}>
          <div class="space-y-2">
            <%= for port <- @free_ports do %>
              <% port_num = Map.get(port, :port, "?") %>
              <% cmd = Map.get(port, :command) || Map.get(port, :process) || Map.get(port, :name, "") %>
              <div class="card bg-base-100 p-3 border border-base-300 flex flex-row items-center gap-4">
                <div class="font-mono text-lg font-bold text-base-content/50"><%= port_num %></div>
                <div class="flex-1 min-w-0">
                  <span class="tooltip tooltip-left block" data-tip={to_string(cmd)}>
                    <div class="text-xs font-semibold truncate"><%= Map.get(port, :name, "unknown") %></div>
                  </span>
                  <div class="text-xs text-base-content/50 truncate"><%= Map.get(port, :project, "") %></div>
                </div>
                <span class="badge badge-xs badge-ghost flex-shrink-0">free</span>
              </div>
            <% end %>
          </div>
        </.collapsible>
      <% end %>
    <% end %>
    """
  end

  defp tab_plugins(assigns) do
    ~H"""
    <%= if Enum.empty?(@session[:plugins] || []) do %>
      <div class="text-center text-base-content/40 text-sm py-8">No plugins loaded</div>
    <% else %>
      <%= for plugin <- @session[:plugins] || [] do %>
        <% name = Map.get(plugin, :name, "unknown") %>
        <% version = Map.get(plugin, :version, "?") %>
        <% description = Map.get(plugin, :description, "") %>
        <% skills = Map.get(plugin, :skills, []) |> List.wrap() %>
        <% commands = Map.get(plugin, :commands, []) |> List.wrap() %>
        <% hooks = Map.get(plugin, :hooks, []) |> List.wrap() %>
        <details class="collapse collapse-arrow bg-base-200 mb-2">
          <summary class="collapse-title text-sm font-semibold">
            <div class="flex items-center justify-between gap-2">
              <span class="truncate"><%= name %></span>
              <span class="badge badge-xs badge-info flex-shrink-0"><%= version %></span>
            </div>
          </summary>
          <div class="collapse-content text-sm">
            <%= if description != "" do %>
              <div class="text-xs text-base-content/60 mb-2"><%= description %></div>
            <% end %>
            <%= if skills != [] do %>
              <div class="text-xs mb-1">
                <span class="text-base-content/40">Skills:</span>
                <span class="text-base-content/70"><%= Enum.join(skills, ", ") %></span>
              </div>
            <% end %>
            <%= if commands != [] do %>
              <div class="text-xs mb-1">
                <span class="text-base-content/40">Commands:</span>
                <span class="text-base-content/70"><%= Enum.join(commands, ", ") %></span>
              </div>
            <% end %>
            <%= if hooks != [] do %>
              <div class="text-xs mb-1">
                <span class="text-base-content/40">Hooks:</span>
                <span class="text-base-content/70"><%= Enum.join(hooks, ", ") %></span>
              </div>
            <% end %>
            <%= if skills == [] and commands == [] and hooks == [] and description == "" do %>
              <div class="text-xs text-base-content/30">No additional metadata</div>
            <% end %>
          </div>
        </details>
      <% end %>
    <% end %>
    """
  end

  # ── Session row component ────────────────────────────────────────────────────

  defp session_row(assigns) do
    sid = to_string(assigns.session[:session_id] || "")
    is_active = to_string(assigns.session[:status] || "") == "active"
    is_selected = assigns.selected && to_string(assigns.selected[:session_id] || "") == sid
    is_hidden = MapSet.member?(assigns.hidden_sessions, sid)

    assigns =
      assigns
      |> assign(:sid, sid)
      |> assign(:is_active, is_active)
      |> assign(:is_selected, is_selected)
      |> assign(:is_hidden, is_hidden)

    ~H"""
    <div class={"relative group #{if @is_hidden, do: "opacity-40"}"}>
      <button
        phx-click="select_session"
        phx-value-id={@sid}
        class={"w-full text-left p-2.5 rounded-lg border transition-colors #{if @is_selected, do: "bg-primary/10 border-primary/30 text-primary", else: "bg-base-100 border-base-300 hover:border-base-content/20"}"}
      >
        <div class="flex items-center gap-2 min-w-0">
          <%= if @is_active do %>
            <div class="w-1.5 h-1.5 rounded-full bg-success animate-pulse flex-shrink-0"></div>
          <% else %>
            <div class="w-1.5 h-1.5 rounded-full bg-base-content/20 flex-shrink-0"></div>
          <% end %>
          <span class="text-xs font-mono truncate">
            <%= NamespaceResolver.session_label(@sid,
                  project: @session[:project_name],
                  branch: @session[:git_branch]) %>
          </span>
        </div>
        <div class="text-[10px] text-zinc-500 font-mono mt-0.5 truncate">
          <%= String.slice(@sid, 0, 12) %>
        </div>
        <div class="flex items-center gap-2 mt-1">
          <%= if @is_active do %>
            <span class="badge badge-xs badge-success">active</span>
          <% else %>
            <span class="badge badge-xs badge-ghost">inactive</span>
          <% end %>
          <%= if (@session[:agent_count] || 0) > 0 do %>
            <span class="text-[10px] text-base-content/40"><%= @session[:agent_count] %> agents</span>
          <% end %>
        </div>
      </button>
      <button
        phx-click="toggle_session_visibility"
        phx-value-id={@sid}
        class="absolute top-1.5 right-1.5 btn btn-ghost btn-xs opacity-0 group-hover:opacity-100 transition-opacity"
        title={if @is_hidden, do: "Show session", else: "Hide session"}
      >
        <%= if @is_hidden do %>
          <.icon name="hero-eye-slash" class="size-3 text-base-content/40" />
        <% else %>
          <.icon name="hero-eye" class="size-3 text-base-content/40" />
        <% end %>
      </button>
    </div>
    """
  end

  # ── Filter and grouping logic ───────────────────────────────────────────────

  defp prepare_session_list(assigns) do
    assigns.sessions
    |> filter_sessions(assigns)
    |> group_sessions(assigns.group_by)
  end

  defp filter_sessions(sessions, assigns) do
    sessions
    |> maybe_filter_hidden(assigns.hidden_sessions, assigns.show_hidden)
    |> maybe_filter_active(assigns.filter_active_only)
    |> maybe_filter_search(assigns.filter_search)
  end

  defp maybe_filter_hidden(sessions, _hidden, true = _show_hidden), do: sessions

  defp maybe_filter_hidden(sessions, hidden, _show_hidden) do
    Enum.reject(sessions, fn s ->
      sid = to_string(s[:session_id] || "")
      MapSet.member?(hidden, sid)
    end)
  end

  defp maybe_filter_active(sessions, false), do: sessions

  defp maybe_filter_active(sessions, true) do
    Enum.filter(sessions, fn s ->
      to_string(s[:status] || "") == "active"
    end)
  end

  defp maybe_filter_search(sessions, ""), do: sessions

  defp maybe_filter_search(sessions, term) do
    normalized = String.downcase(term)

    Enum.filter(sessions, fn s ->
      searchable =
        [
          to_string(s[:session_id] || ""),
          to_string(s[:project_name] || ""),
          to_string(s[:project_root] || ""),
          to_string(s[:git_branch] || ""),
          to_string(s[:slug] || "")
        ]
        |> Enum.join(" ")
        |> String.downcase()

      String.contains?(searchable, normalized)
    end)
  end

  defp group_sessions(sessions, "none"), do: [{"All Sessions", sessions}]

  defp group_sessions(sessions, "project") do
    sessions
    |> Enum.group_by(fn s -> to_string(s[:project_name] || "Unknown") end)
    |> Enum.sort_by(fn {name, _} -> String.downcase(name) end)
  end

  defp group_sessions(sessions, "context") do
    sessions
    |> Enum.group_by(&detect_init_context/1)
    |> Enum.sort_by(fn {name, _} -> String.downcase(name) end)
  end

  defp group_sessions(sessions, "working_context") do
    sessions
    |> Enum.group_by(&detect_working_context/1)
    |> Enum.sort_by(fn {name, _} -> String.downcase(name) end)
  end

  defp group_sessions(sessions, "date") do
    today = Date.utc_today()
    yesterday = Date.add(today, -1)
    week_ago = Date.add(today, -7)

    sessions
    |> Enum.group_by(fn s -> date_bucket(s, today, yesterday, week_ago) end)
    |> Enum.sort_by(fn {name, _} -> date_bucket_order(name) end)
  end

  defp group_sessions(sessions, _), do: [{"All Sessions", sessions}]

  defp date_bucket(session, today, yesterday, week_ago) do
    case parse_session_date(session[:start_time]) do
      nil -> "Unknown"
      date ->
        cond do
          Date.compare(date, today) == :eq -> "Today"
          Date.compare(date, yesterday) == :eq -> "Yesterday"
          Date.compare(date, week_ago) in [:gt, :eq] -> "Last 7 days"
          true -> "Older"
        end
    end
  end

  defp date_bucket_order("Today"), do: 0
  defp date_bucket_order("Yesterday"), do: 1
  defp date_bucket_order("Last 7 days"), do: 2
  defp date_bucket_order("Older"), do: 3
  defp date_bucket_order(_), do: 4

  defp parse_session_date(nil), do: nil
  defp parse_session_date(""), do: nil

  defp parse_session_date(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> DateTime.to_date(dt)
      _ -> nil
    end
  end

  defp parse_session_date(_), do: nil

  defp detect_init_context(session) do
    slug = to_string(session[:slug] || "") |> String.downcase()
    project_root = to_string(session[:project_root] || "") |> String.downcase()
    branch = to_string(session[:git_branch] || "") |> String.downcase()

    combined = slug <> " " <> project_root <> " " <> branch

    cond do
      String.contains?(combined, "ralph") -> "Ralph"
      String.contains?(combined, "formation") -> "Formation"
      String.contains?(combined, "upm") -> "UPM"
      String.contains?(combined, "plane") -> "Plane PM"
      String.contains?(combined, "coalesce") -> "Coalesce"
      String.contains?(combined, "tdd") -> "TDD"
      String.contains?(combined, "fix") -> "Fix Loop"
      session[:source] == :claude_native -> "Claude Native"
      true -> "Manual"
    end
  end

  defp detect_working_context(session) do
    project_root = to_string(session[:project_root] || "")
    branch = to_string(session[:git_branch] || "")

    cond do
      String.contains?(project_root, ".claude/worktrees/") ->
        worktree_name =
          project_root
          |> String.split(".claude/worktrees/")
          |> List.last()
          |> String.split("/")
          |> List.first()

        "Worktree: #{worktree_name}"

      branch != "" ->
        "Branch: #{branch}"

      true ->
        "Default"
    end
  end

  # ── Small reusable components ────────────────────────────────────────────────

  defp stat_card(assigns) do
    assigns = assign_new(assigns, :icon, fn -> "hero-chart-bar" end)

    ~H"""
    <div class="card bg-base-200 p-3">
      <div class="flex items-center gap-2 mb-1">
        <.icon name={@icon} class="size-3.5 text-base-content/40" />
        <span class="text-xs text-base-content/50"><%= @label %></span>
      </div>
      <div class="text-2xl font-bold text-base-content"><%= @value %></div>
    </div>
    """
  end

  defp info_row(assigns) do
    assigns = assign_new(assigns, :mono, fn -> false end)

    ~H"""
    <div class="flex gap-3 text-xs">
      <div class="w-28 flex-shrink-0 text-base-content/40 font-semibold"><%= @label %></div>
      <div class={"flex-1 truncate #{if @mono, do: "font-mono text-base-content/70", else: "text-base-content/70"}"}><%= @value %></div>
    </div>
    """
  end

  defp status_badge_class("active"), do: "badge-success"
  defp status_badge_class("completed"), do: "badge-info"
  defp status_badge_class("error"), do: "badge-error"
  defp status_badge_class(_), do: "badge-ghost"

  # ── Diagram payload builders ─────────────────────────────────────────────────

  # Topology diagram: project root at center, CLAUDE.md above, skills/agents/
  # hooks/plugins/MCP orbiting around.
  @spec build_topology_payload(map()) :: %{nodes: list(map()), edges: list(map())}
  defp build_topology_payload(session) do
    config = session[:claude_config] || %{}
    project_name = to_string(session[:project_name] || "project")

    center = %{
      id: "project",
      label: project_name,
      type: "root",
      x: 250,
      y: 200
    }

    claude_md = %{
      id: "claude_md",
      label: "CLAUDE.md",
      type: if(config[:has_claude_md], do: "present", else: "absent"),
      x: 250,
      y: 60
    }

    satellites = [
      %{id: "agents", label: "Agents · #{session[:agent_count] || 0}", type: "agents", x: 60, y: 130},
      %{id: "ports", label: "Ports · #{session[:port_count] || 0}", type: "ports", x: 440, y: 130},
      %{id: "plugins", label: "Plugins · #{session[:plugin_count] || 0}", type: "plugins", x: 60, y: 270},
      %{id: "skills", label: "Skills · #{config[:skill_count] || 0}", type: "skills", x: 440, y: 270},
      %{id: "hooks", label: "Hooks · #{config[:hook_count] || 0}", type: "hooks", x: 250, y: 340}
    ]

    nodes = [center, claude_md | satellites]

    edges =
      [
        %{from: "claude_md", to: "project", label: "config"},
        %{from: "project", to: "agents", label: ""},
        %{from: "project", to: "ports", label: ""},
        %{from: "project", to: "plugins", label: ""},
        %{from: "project", to: "skills", label: ""},
        %{from: "project", to: "hooks", label: ""}
      ]

    %{nodes: nodes, edges: edges}
  end

  # Hook lifecycle: fixed 6-phase ring representing the Claude Code hook chain.
  # Counts are synthesised from the aggregate `hook_count` scan — individual
  # phase counts aren't tracked in `scan_claude_config/1`, so we distribute the
  # total across phases equally as an approximation.
  @spec build_hook_lifecycle_payload(map()) :: %{nodes: list(map()), edges: list(map())}
  defp build_hook_lifecycle_payload(config) do
    total = config[:hook_count] || 0

    phases = [
      {"session_start", "SessionStart"},
      {"user_prompt", "UserPromptSubmit"},
      {"pre_tool", "PreToolUse"},
      {"post_tool", "PostToolUse"},
      {"stop", "Stop"},
      {"session_end", "SessionEnd"}
    ]

    cx = 250
    cy = 180
    radius = 130
    count = length(phases)

    nodes =
      phases
      |> Enum.with_index()
      |> Enum.map(fn {{id, label}, i} ->
        angle = :math.pi() * 2 * i / count - :math.pi() / 2
        %{
          id: id,
          label: label,
          type: "hook_phase",
          x: round(cx + radius * :math.cos(angle)),
          y: round(cy + radius * :math.sin(angle)),
          count: div(total, count)
        }
      end)

    edges =
      phases
      |> Enum.with_index()
      |> Enum.map(fn {{id, _}, i} ->
        {next_id, _} = Enum.at(phases, rem(i + 1, count))
        %{from: id, to: next_id, label: ""}
      end)

    %{nodes: nodes, edges: edges}
  end

  # Formation tree: builds parent → child edges from agents' `parent_agent_id`.
  # Nodes are laid out in columns by wave, with squadron leads highlighted.
  @spec build_formation_tree_payload(list(map())) :: %{nodes: list(map()), edges: list(map())}
  defp build_formation_tree_payload(agents) when is_list(agents) do
    # Group agents by wave to determine horizontal slotting
    by_wave =
      agents
      |> Enum.group_by(fn a -> Map.get(a, :wave, Map.get(a, :wave_number, 0)) || 0 end)
      |> Enum.sort_by(fn {wave, _} -> wave end)

    col_width = 170
    row_height = 70
    base_x = 40
    base_y = 40

    {nodes, _} =
      Enum.reduce(by_wave, {[], 0}, fn {wave, wave_agents}, {acc, col_idx} ->
        new_nodes =
          wave_agents
          |> Enum.with_index()
          |> Enum.map(fn {agent, row_idx} ->
            agent_id = to_string(Map.get(agent, :agent_id, ""))
            formation_role = to_string(Map.get(agent, :formation_role, ""))

            label =
              Map.get(agent, :display_name) ||
                NamespaceResolver.agent_label(agent_id,
                  role: Map.get(agent, :role),
                  task_subject: Map.get(agent, :task_subject),
                  formation_id: Map.get(agent, :formation_id),
                  project: Map.get(agent, :project)
                )

            %{
              id: agent_id,
              label: truncate(label, 22),
              type: formation_role_type(formation_role),
              wave: wave,
              x: base_x + col_idx * col_width,
              y: base_y + row_idx * row_height
            }
          end)

        {acc ++ new_nodes, col_idx + 1}
      end)

    node_ids = MapSet.new(nodes, & &1.id)

    edges =
      agents
      |> Enum.flat_map(fn agent ->
        parent = to_string(Map.get(agent, :parent_agent_id, "") || "")
        child = to_string(Map.get(agent, :agent_id, "") || "")

        if parent != "" and child != "" and MapSet.member?(node_ids, parent) and
             MapSet.member?(node_ids, child) do
          [%{from: parent, to: child, label: ""}]
        else
          []
        end
      end)

    %{nodes: nodes, edges: edges}
  end

  defp build_formation_tree_payload(_), do: %{nodes: [], edges: []}

  defp formation_role_type("squadron_lead"), do: "lead"
  defp formation_role_type("orchestrator"), do: "lead"
  defp formation_role_type("swarm_agent"), do: "swarm"
  defp formation_role_type("cluster_agent"), do: "cluster"
  defp formation_role_type(_), do: "agent"

  defp truncate(str, n) when is_binary(str) do
    if String.length(str) > n, do: String.slice(str, 0, n - 1) <> "…", else: str
  end

  defp truncate(other, _), do: to_string(other)

  # Renders a relative-time string for session freshness ("2m ago", "1h ago").
  defp format_freshness(nil), do: "—"
  defp format_freshness(""), do: "—"

  defp format_freshness(iso8601) when is_binary(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)

        cond do
          diff < 5 -> "just now"
          diff < 60 -> "#{diff}s ago"
          diff < 3600 -> "#{div(diff, 60)}m ago"
          diff < 86_400 -> "#{div(diff, 3600)}h ago"
          true -> "#{div(diff, 86_400)}d ago"
        end

      _ ->
        "—"
    end
  end

  defp format_freshness(_), do: "—"

  # ── Markdown rendering helper ────────────────────────────────────────────────

  @doc false
  # Renders a raw markdown string into safe HTML via Earmark.
  # Returns nil for nil/empty input so callers can gate rendering trivially.
  @spec render_markdown(String.t() | nil) :: Phoenix.HTML.safe() | nil
  defp render_markdown(nil), do: nil
  defp render_markdown(""), do: nil

  defp render_markdown(text) when is_binary(text) do
    html =
      try do
        Earmark.as_html!(text, compact_output: false, gfm: true, breaks: false)
      rescue
        _ -> Phoenix.HTML.html_escape(text) |> Phoenix.HTML.safe_to_string()
      end

    Phoenix.HTML.raw(html)
  end

  defp render_markdown(_), do: nil

  # ── Collapsible section component ────────────────────────────────────────────

  # Reusable daisyUI collapse/arrow wrapper. Matches the house pattern used in
  # the left-panel session list and dashboard widgets.
  attr :title, :string, required: true
  attr :open, :boolean, default: false
  slot :inner_block, required: true

  defp collapsible(assigns) do
    ~H"""
    <details class="collapse collapse-arrow bg-base-200 mb-2" open={@open}>
      <summary class="collapse-title text-sm font-semibold"><%= @title %></summary>
      <div class="collapse-content text-sm">
        <%= render_slot(@inner_block) %>
      </div>
    </details>
    """
  end
end
