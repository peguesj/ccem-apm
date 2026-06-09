defmodule ApmWeb.OpenDesignLive do
  @moduledoc """
  LiveView for the open-design plugin at `/plugins/open-design`.

  Three tabs:
  - **Status**  — daemon health, version, detected agents, summary stats.
  - **Skills**  — skill catalog from the daemon's registry.
  - **Projects** — projects + design systems managed by the daemon.

  Subscribes to `"open_design:state"` PubSub for live daemon state updates.
  """

  use ApmWeb, :live_view

  require Logger

  alias Apm.Plugins.OpenDesign.OpenDesignClient

  @pubsub_topic "open_design:state"
  @daemon_port 17_456

  # ── Mount ──────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Apm.PubSub, @pubsub_topic)
    end

    daemon_state = safe_monitor_state()

    socket =
      socket
      |> assign(:page_title, "open-design")
      |> assign(:daemon_state, daemon_state)
      |> assign(:active_tab, "status")
      |> assign(:skills, [])
      |> assign(:design_systems, [])
      |> assign(:projects, [])
      |> assign(:agents, daemon_state[:agents] || [])
      |> assign(:loading, false)
      |> assign(:error, nil)
      |> assign(:notification_count, 0)
      |> assign(:skill_count, 0)
      |> assign(:sidebar_collapsed, false)
      |> assign(:inspector_open, false)
      |> ApmWeb.Components.SidebarNav.assign_sidebar_nav_data()

    {:ok, socket}
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <ApmWeb.Components.SidebarNav.sidebar_nav
          current_path="/plugins/open-design"
          notification_count={@notification_count}
          skill_count={@skill_count}
        />
      </:sidebar>

      <:main>
        <div class="flex flex-col h-full">
          <%!-- Header --%>
          <div class="flex items-center justify-between px-6 py-4 border-b border-base-300">
            <div class="flex items-center gap-3">
              <.icon name="hero-paint-brush" class="w-5 h-5 text-primary" />
              <h1 class="text-lg font-semibold">open-design</h1>
              <.badge :if={@daemon_state[:reachable]} tone="success">daemon online</.badge>
              <.badge :if={!@daemon_state[:reachable]} tone="error">daemon offline</.badge>
            </div>
            <div class="flex items-center gap-2 text-sm text-base-content/60">
              <%= if @daemon_state[:version] do %>
                <span>v{@daemon_state[:version]}</span>
                <span>·</span>
              <% end %>
              <span>port {@daemon_state[:port] || @daemon_port}</span>
              <span>·</span>
              <a
                href="http://localhost:{@daemon_port}"
                target="_blank"
                class="link link-primary text-xs"
              >
                open UI
              </a>
            </div>
          </div>

          <%!-- Tab bar --%>
          <div class="tabs tabs-bordered px-6 pt-3">
            <button
              class={"tab #{if @active_tab == "status", do: "tab-active"}"}
              phx-click="set_tab"
              phx-value-tab="status"
            >
              Status
            </button>
            <button
              class={"tab #{if @active_tab == "skills", do: "tab-active"}"}
              phx-click="set_tab"
              phx-value-tab="skills"
            >
              Skills
              <%= if length(@skills) > 0 do %>
                <.badge tone="neutral" class="ml-1">{length(@skills)}</.badge>
              <% end %>
            </button>
            <button
              class={"tab #{if @active_tab == "projects", do: "tab-active"}"}
              phx-click="set_tab"
              phx-value-tab="projects"
            >
              Projects
              <%= if length(@projects) > 0 do %>
                <.badge tone="neutral" class="ml-1">{length(@projects)}</.badge>
              <% end %>
            </button>
          </div>

          <%!-- Tab content --%>
          <div class="flex-1 overflow-auto px-6 py-4">
            <%= if @loading do %>
              <div class="flex items-center gap-2 text-base-content/60">
                <span class="loading loading-spinner loading-sm"></span>
                <span>Loading…</span>
              </div>
            <% else %>
              <%= if @error do %>
                <div class="alert alert-error mb-4">
                  <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
                  <span>{@error}</span>
                </div>
              <% end %>

              <%= case @active_tab do %>
                <% "status" -> %>
                  <.render_status daemon_state={@daemon_state} agents={@agents} />
                <% "skills" -> %>
                  <.render_skills skills={@skills} daemon_state={@daemon_state} />
                <% "projects" -> %>
                  <.render_projects
                    projects={@projects}
                    design_systems={@design_systems}
                    daemon_state={@daemon_state}
                  />
              <% end %>
            <% end %>
          </div>
        </div>
      </:main>
    </.page_layout>
    """
  end

  # ── Tab Partials ────────────────────────────────────────────────────────────

  defp render_status(assigns) do
    ~H"""
    <div class="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
      <.stat_tile label="Status" value={if @daemon_state[:reachable], do: "Online", else: "Offline"} />
      <.stat_tile label="Skills" value={to_string(@daemon_state[:skill_count] || 0)} />
      <.stat_tile label="Design Systems" value={to_string(@daemon_state[:design_system_count] || 0)} />
      <.stat_tile label="Projects" value={to_string(@daemon_state[:project_count] || 0)} />
    </div>

    <%= if length(@agents) > 0 do %>
      <div class="mb-4">
        <h2 class="text-sm font-medium text-base-content/70 mb-2 uppercase tracking-wide">
          Detected Agents
        </h2>
        <div class="flex flex-wrap gap-2">
          <%= for agent <- @agents do %>
            <.badge tone="accent">{agent_label(agent)}</.badge>
          <% end %>
        </div>
      </div>
    <% else %>
      <div class="text-sm text-base-content/50 mb-4">No agents detected.</div>
    <% end %>

    <div class="text-xs text-base-content/40 mt-6">
      Last polled: {@daemon_state[:last_checked] || "—"}
    </div>
    """
  end

  defp render_skills(assigns) do
    ~H"""
    <%= if length(@skills) == 0 and @daemon_state[:reachable] do %>
      <button class="btn btn-sm btn-outline" phx-click="load_skills">Load Skills</button>
    <% end %>
    <div class="space-y-2">
      <%= for skill <- @skills do %>
        <div class="card card-compact bg-base-200">
          <div class="card-body">
            <div class="flex items-start justify-between">
              <div>
                <span class="font-medium">{skill_name(skill)}</span>
                <%= if skill["description"] do %>
                  <p class="text-sm text-base-content/60 mt-0.5">{skill["description"]}</p>
                <% end %>
              </div>
              <%= if skill["version"] do %>
                <.badge tone="neutral" class="shrink-0 ml-2">v{skill["version"]}</.badge>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_projects(assigns) do
    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
      <%= if length(@projects) > 0 do %>
        <div>
          <h2 class="text-sm font-medium text-base-content/70 mb-2 uppercase tracking-wide">
            Projects ({length(@projects)})
          </h2>
          <div class="space-y-2">
            <%= for project <- @projects do %>
              <div class="card card-compact bg-base-200">
                <div class="card-body">
                  <span class="font-medium">{project["name"] || project["id"] || "Unnamed"}</span>
                  <%= if project["description"] do %>
                    <p class="text-sm text-base-content/60">{project["description"]}</p>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% else %>
        <%= if @daemon_state[:reachable] do %>
          <button class="btn btn-sm btn-outline" phx-click="load_projects">Load Projects</button>
        <% end %>
      <% end %>

      <%= if length(@design_systems) > 0 do %>
        <div>
          <h2 class="text-sm font-medium text-base-content/70 mb-2 uppercase tracking-wide">
            Design Systems ({length(@design_systems)})
          </h2>
          <div class="space-y-2">
            <%= for ds <- @design_systems do %>
              <div class="card card-compact bg-base-200">
                <div class="card-body">
                  <span class="font-medium">{ds["name"] || ds["id"] || "Unnamed"}</span>
                  <%= if ds["description"] do %>
                    <p class="text-sm text-base-content/60">{ds["description"]}</p>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Events ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("set_tab", %{"tab" => "skills"}, socket) do
    socket = assign(socket, :active_tab, "skills") |> assign(:loading, true)
    send(self(), :fetch_skills)
    {:noreply, socket}
  end

  def handle_event("set_tab", %{"tab" => "projects"}, socket) do
    socket = assign(socket, :active_tab, "projects") |> assign(:loading, true)
    send(self(), :fetch_projects)
    {:noreply, socket}
  end

  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("load_skills", _params, socket) do
    send(self(), :fetch_skills)
    {:noreply, assign(socket, :loading, true)}
  end

  def handle_event("load_projects", _params, socket) do
    send(self(), :fetch_projects)
    {:noreply, assign(socket, :loading, true)}
  end

  # ── Info ────────────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:open_design_state_updated, new_state}, socket) do
    {:noreply, assign(socket, :daemon_state, new_state)}
  end

  def handle_info(:fetch_skills, socket) do
    {skills, error} =
      case OpenDesignClient.list_skills(@daemon_port) do
        {:ok, s} -> {s, nil}
        {:error, reason} -> {[], "Could not load skills: #{inspect(reason)}"}
      end

    {:noreply,
     socket |> assign(:skills, skills) |> assign(:error, error) |> assign(:loading, false)}
  end

  def handle_info(:fetch_projects, socket) do
    projects =
      case OpenDesignClient.list_projects(@daemon_port) do
        {:ok, ps} -> ps
        _ -> []
      end

    design_systems =
      case OpenDesignClient.list_design_systems(@daemon_port) do
        {:ok, ds} -> ds
        _ -> []
      end

    {:noreply,
     socket
     |> assign(:projects, projects)
     |> assign(:design_systems, design_systems)
     |> assign(:loading, false)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp safe_monitor_state do
    case Process.whereis(Apm.Plugins.OpenDesign.OpenDesignMonitor) do
      nil ->
        %{
          reachable: false,
          agents: [],
          skill_count: 0,
          design_system_count: 0,
          project_count: 0,
          port: @daemon_port,
          last_checked: nil
        }

      _pid ->
        Apm.Plugins.OpenDesign.OpenDesignMonitor.current_state()
    end
  rescue
    _ ->
      %{
        reachable: false,
        agents: [],
        skill_count: 0,
        design_system_count: 0,
        project_count: 0,
        port: @daemon_port,
        last_checked: nil
      }
  end

  defp agent_label(agent) when is_map(agent), do: agent["name"] || agent["id"] || inspect(agent)
  defp agent_label(agent) when is_binary(agent), do: agent
  defp agent_label(agent), do: inspect(agent)

  defp skill_name(skill) when is_map(skill), do: skill["name"] || skill["id"] || "Unknown"
  defp skill_name(skill) when is_binary(skill), do: skill
  defp skill_name(_), do: "Unknown"
end
