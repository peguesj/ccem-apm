defmodule ApmV5Web.ShowcaseLive do
  @moduledoc """
  Showcase LiveView — GIMME-style dashboard integrated into APM chrome.

  Supports:
  - /showcase           → active project from config
  - /showcase/:project  → named project via push_patch (async URL update)
  - Iframe mode for migrated standalone showcases (priv/static/showcase/projects/:name/)
  - Fullscreen toggle (covers APM chrome, Esc to exit)
  """

  use ApmV5Web, :live_view


  alias ApmV5.AgentRegistry
  alias ApmV5.AgUi.ActivityTracker
  alias ApmV5.ConfigLoader
  alias ApmV5.ShowcaseDataStore
  alias ApmV5.UpmStore

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:agents")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:config")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:upm")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "ag_ui:events")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:showcase")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:activity_log")

      :timer.send_interval(5_000, self(), :heartbeat_push)
    end

    config = safe_get_config()
    all_projects = Map.get(config, "projects", [])
    showcase_projects = ShowcaseDataStore.filter_showcase_projects(all_projects)

    socket =
      socket
      |> assign(:page_title, "Showcase")
      |> assign(:all_projects, all_projects)
      |> assign(:showcase_projects, showcase_projects)
      |> assign(:active_project, nil)
      |> assign(:showcase_data, %{})
      |> assign(:features, [])
      |> assign(:version, "5.5.0")
      |> assign(:showcase_initialized, false)
      |> assign(:activity_log, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"project" => project}, _uri, socket) do
    load_project(project, socket)
  end

  def handle_params(_params, _uri, socket) do
    config = safe_get_config()
    project = Map.get(config, "active_project")
    load_project(project, socket)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <.sidebar_nav current_path="/showcase" />

      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Header --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Showcase</h2>
            <div class="badge badge-sm badge-ghost">{length(@features)} features</div>
            <div class="badge badge-sm badge-accent gap-1">
              <span class="inline-block w-1.5 h-1.5 rounded-full bg-accent animate-pulse"></span>
              LIVE
            </div>

            <%!-- Project selector — only shows projects that have showcase data --%>
            <div class="dropdown dropdown-bottom">
              <div tabindex="0" role="button" class="btn btn-ghost btn-xs gap-1">
                <.icon name="hero-presentation-chart-bar" class="size-3" />
                {@active_project || "ccem"}
                <.icon name="hero-chevron-down" class="size-3" />
              </div>
              <ul tabindex="0" class="dropdown-content z-50 menu menu-xs p-1 bg-base-200 border border-base-300 rounded-box shadow-lg w-52">
                <li :if={length(@showcase_projects) == 0}>
                  <span class="text-base-content/40 italic">No other showcases</span>
                </li>
                <li :for={project <- @showcase_projects}>
                  <button
                    phx-click="switch_project"
                    phx-value-project={project["name"]}
                    class={@active_project == project["name"] && "active"}
                  >
                    <.icon name="hero-presentation-chart-bar" class="size-3 opacity-60" />
                    {project["name"]}
                  </button>
                </li>
                <li :if={length(@all_projects) > length(@showcase_projects)} class="menu-title mt-1">
                  <span class="text-[10px] text-base-content/30">
                    {length(@all_projects) - length(@showcase_projects)} project(s) without showcase — run Migrate action
                  </span>
                </li>
              </ul>
            </div>
          </div>

          <div class="flex items-center gap-2 text-xs text-base-content/50">
            <span class="font-mono">v{@version}</span>
            <button
              id="showcase-fullscreen-btn"
              phx-click={JS.dispatch("showcase:fullscreen", to: "#showcase-container")}
              class="btn btn-ghost btn-xs p-1"
              title="Toggle fullscreen (Esc to exit)"
            >
              <span data-expand><.icon name="hero-arrows-pointing-out" class="size-4" /></span>
              <span data-collapse style="display:none"><.icon name="hero-arrows-pointing-in" class="size-4" /></span>
            </button>
          </div>
        </header>

        <%!-- Showcase container — ShowcaseHook mounts here; engine targets inner phx-update=ignore div --%>
        <div
          id="showcase-container"
          phx-hook="ShowcaseHook"
          data-project={@active_project || "ccem"}
          data-version={@version}
          data-features={Jason.encode!(@features)}
          data-static-path={static_showcase_path(@active_project)}
          class="flex-1 overflow-hidden showcase-scope"
        >
          <%!-- phx-update=ignore prevents LiveView morphdom from patching engine-owned DOM --%>
          <div id="showcase-engine-root" phx-update="ignore" class="h-full">
            <div class="flex items-center justify-center h-full text-base-content/30 text-sm font-mono text-xs">
              initializing showcase engine...
            </div>
          </div>
        </div>
      </div>
    </div>
    <.wizard page="showcase" />
    """
  end

  # --- Events ---

  @impl true
  def handle_event("switch_project", %{"project" => name}, socket) do
    {:noreply, push_patch(socket, to: ~p"/showcase/#{name}")}
  end

  def handle_event("switch_template", %{"template" => template}, socket) do
    {:noreply, push_event(socket, "showcase:template-changed", %{template: template})}
  end

  # --- PubSub Handlers ---

  @impl true
  def handle_info(:heartbeat_push, socket) do
    push_apm_data(socket)
  end

  def handle_info({:agent_registered, _}, socket), do: push_agents(socket)
  def handle_info({:agent_updated, _}, socket), do: push_agents(socket)
  def handle_info({:upm_event, _data}, socket), do: push_orch(socket)

  def handle_info({:activity_log_entry, entry}, socket) do
    log = [entry | (socket.assigns[:activity_log] || [])] |> Enum.take(99)
    activities = safe_list_activities()

    socket =
      socket
      |> assign(:activity_log, log)
      |> push_event("showcase:activity", %{agents: activities, log: log})

    {:noreply, socket}
  end

  def handle_info({:config_reloaded, config}, socket) do
    all_projects = Map.get(config, "projects", [])
    showcase_projects = ShowcaseDataStore.filter_showcase_projects(all_projects)

    {:noreply,
     socket
     |> assign(:all_projects, all_projects)
     |> assign(:showcase_projects, showcase_projects)}
  end

  def handle_info({:showcase_data_reloaded, project, data}, socket) do
    if project == (socket.assigns.active_project || "ccem") do
      features = Map.get(data, "features", [])
      version = Map.get(data, "version", "5.5.0")

      {:noreply,
       socket
       |> assign(:showcase_data, data)
       |> assign(:features, features)
       |> assign(:version, version)
       |> push_event("showcase:project-changed", %{
         project: project,
         version: version,
         features: features,
         staticPath: static_showcase_path(project)
       })}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private ---

  defp load_project(project, socket) do
    was_initialized = socket.assigns.showcase_initialized
    showcase_data = ShowcaseDataStore.get_showcase_data(project)
    features = Map.get(showcase_data, "features", [])
    version = Map.get(showcase_data, "version", "5.5.0")
    static_path = static_showcase_path(project)

    socket =
      socket
      |> assign(:active_project, project)
      |> assign(:showcase_data, showcase_data)
      |> assign(:features, features)
      |> assign(:version, version)
      |> assign(:showcase_initialized, true)

    # Only push project-changed event on subsequent navigations (not initial mount)
    # On initial mount the hook reads data-attributes directly from the DOM
    socket =
      if was_initialized do
        push_event(socket, "showcase:project-changed", %{
          project: project,
          version: version,
          features: features,
          staticPath: static_path
        })
      else
        socket
      end

    {:noreply, socket}
  end

  # Returns the static serve path if a migrated project showcase exists under
  # priv/static/showcase/projects/{name}/index.html, else empty string.
  defp static_showcase_path(nil), do: ""

  defp static_showcase_path(project) when is_binary(project) do
    static_file =
      Path.join([
        to_string(:code.priv_dir(:apm_v5)),
        "static",
        "showcase",
        "projects",
        project,
        "index.html"
      ])

    if File.exists?(static_file), do: "/showcase/projects/#{project}/index.html", else: ""
  end

  defp static_showcase_path(_), do: ""

  defp push_apm_data(socket) do
    agents = AgentRegistry.list_agents(socket.assigns.active_project)
    active_count = Enum.count(agents, fn a -> a.status in ["active", "working"] end)

    apm_data = %{
      connected: true,
      apmConn: "live",
      projectConn: if(socket.assigns.active_project, do: "live", else: "off"),
      status: %{
        server: "APM v5",
        version: socket.assigns.version,
        uptime: format_uptime()
      }
    }

    activities = safe_list_activities()
    log = socket.assigns[:activity_log] || []

    socket =
      socket
      |> push_event("showcase:data", apm_data)
      |> push_event("showcase:agents", %{agents: serialize_agents(agents)})
      |> push_event("showcase:activity", %{agents: activities, log: log})

    orch_data = build_orch_data(socket.assigns.active_project, active_count, length(agents))
    {:noreply, push_event(socket, "showcase:orch", orch_data)}
  end

  defp push_agents(socket) do
    agents = AgentRegistry.list_agents(socket.assigns.active_project)

    {:noreply,
     push_event(socket, "showcase:agents", %{agents: serialize_agents(agents)})}
  end

  defp push_orch(socket) do
    agents = AgentRegistry.list_agents(socket.assigns.active_project)
    active_count = Enum.count(agents, fn a -> a.status in ["active", "working"] end)
    orch_data = build_orch_data(socket.assigns.active_project, active_count, length(agents))
    {:noreply, push_event(socket, "showcase:orch", orch_data)}
  end

  defp build_orch_data(_project, active_count, total_count) do
    upm_status =
      try do
        result = UpmStore.get_status()
        if is_map(result), do: result, else: %{}
      catch
        :exit, _ -> %{}
        _, _ -> %{}
      end

    session = upm_status |> Map.get(:session) |> then(fn s -> if is_map(s), do: s, else: %{} end)

    %{
      phase: Map.get(session, :phase, "ship"),
      wave: Map.get(session, :wave, 5),
      totalWaves: Map.get(session, :total_waves, 5),
      agentsActive: active_count,
      agentsTotal: total_count,
      tsc: Map.get(session, :tsc_gate, "PASS"),
      formation_id: Map.get(session, :formation_id)
    }
  end

  defp serialize_agents(agents) do
    Enum.map(agents, fn a ->
      %{id: a.id, agent_id: a.id, name: a.name, status: a.status}
    end)
  end

  defp format_uptime do
    start = Application.get_env(:apm_v5, :server_start_time, System.monotonic_time(:second))
    elapsed = System.monotonic_time(:second) - start
    hours = div(elapsed, 3600)
    minutes = div(rem(elapsed, 3600), 60)
    "#{hours}h #{minutes}m"
  end

  defp safe_get_config do
    try do
      ConfigLoader.get_config()
    catch
      :exit, _ -> %{"projects" => [], "active_project" => nil}
    end
  end

  defp safe_list_activities do
    try do
      ActivityTracker.list_activities()
    catch
      :exit, _ -> %{}
    end
  end
end
