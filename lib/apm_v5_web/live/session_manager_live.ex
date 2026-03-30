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
     assign(socket,
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
     )}
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
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <.sidebar_nav
        current_path={@current_path}
        notification_count={@notification_count}
        skill_count={@skill_count}
      />

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
    </div>
    """
  end

  # ── Tab components ───────────────────────────────────────────────────────────

  defp tab_overview(assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-4 mb-6">
      <.stat_card label="Agents" value={@session[:agent_count] || 0} icon="hero-user-group" />
      <.stat_card label="Ports" value={@session[:port_count] || 0} icon="hero-signal" />
      <.stat_card label="Plugins" value={@session[:plugin_count] || 0} icon="hero-puzzle-piece" />
      <.stat_card label="Skills" value={get_in(@session, [:claude_config, :skill_count]) || 0} icon="hero-sparkles" />
    </div>

    <div class="space-y-3">
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
    """
  end

  defp tab_claude_config(assigns) do
    config = assigns.session[:claude_config] || %{}

    assigns = assign(assigns, :config, config)

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
      <div class="card bg-base-200 p-4">
        <div class="text-xs font-semibold text-base-content/50 mb-2">CLAUDE.md Preview</div>
        <pre class="text-xs text-base-content/70 whitespace-pre-wrap font-mono overflow-hidden max-h-64"><%= @config[:claude_md_preview] %></pre>
        <%= if String.length(@config[:claude_md_preview] || "") >= 498 do %>
          <div class="text-xs text-base-content/30 mt-1">... (truncated)</div>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp tab_agents(assigns) do
    ~H"""
    <%= if Enum.empty?(@session[:agents] || []) do %>
      <div class="text-center text-base-content/40 text-sm py-8">No agents registered for this session</div>
    <% else %>
      <div class="space-y-2">
        <%= for agent <- @session[:agents] || [] do %>
          <div class="card bg-base-200 p-3">
            <div class="flex items-center justify-between">
              <div class="font-mono text-xs truncate"><%= Map.get(agent, :agent_id, "unknown") %></div>
              <span class={"badge badge-xs #{status_badge_class(Map.get(agent, :status, ""))}"}>
                <%= Map.get(agent, :status, "unknown") %>
              </span>
            </div>
            <div class="text-xs text-base-content/50 mt-1">
              Role: <%= Map.get(agent, :role, "—") %> · Wave: <%= Map.get(agent, :wave, "—") %>
            </div>
            <%= if Map.get(agent, :task_subject) do %>
              <div class="text-xs text-base-content/60 mt-0.5 truncate"><%= Map.get(agent, :task_subject) %></div>
            <% end %>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp tab_ports(assigns) do
    ~H"""
    <%= if Enum.empty?(@session[:ports] || []) do %>
      <div class="text-center text-base-content/40 text-sm py-8">No ports bound to this project</div>
    <% else %>
      <div class="space-y-2">
        <%= for port <- @session[:ports] || [] do %>
          <div class="card bg-base-200 p-3 flex flex-row items-center gap-4">
            <div class="font-mono text-lg font-bold text-primary"><%= Map.get(port, :port, "?") %></div>
            <div class="flex-1 min-w-0">
              <div class="text-xs font-semibold truncate"><%= Map.get(port, :name, "unknown") %></div>
              <div class="text-xs text-base-content/50 truncate"><%= Map.get(port, :project, "") %></div>
            </div>
            <span class={"badge badge-xs #{if Map.get(port, :in_use), do: "badge-success", else: "badge-ghost"}"}>
              <%= if Map.get(port, :in_use), do: "in use", else: "free" %>
            </span>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp tab_plugins(assigns) do
    ~H"""
    <%= if Enum.empty?(@session[:plugins] || []) do %>
      <div class="text-center text-base-content/40 text-sm py-8">No plugins loaded</div>
    <% else %>
      <div class="space-y-2">
        <%= for plugin <- @session[:plugins] || [] do %>
          <div class="card bg-base-200 p-3">
            <div class="flex items-center justify-between">
              <div class="font-semibold text-sm"><%= Map.get(plugin, :name, "unknown") %></div>
              <span class="badge badge-xs badge-info"><%= Map.get(plugin, :version, "?") %></span>
            </div>
            <div class="text-xs text-base-content/50 mt-0.5">
              <%= Map.get(plugin, :description, "") %>
            </div>
          </div>
        <% end %>
      </div>
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

  defp group_sessions(sessions, _), do: [{"All Sessions", sessions}]

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
end
