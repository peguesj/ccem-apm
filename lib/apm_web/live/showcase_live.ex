defmodule ApmWeb.ShowcaseLive do
  @moduledoc """
  Showcase LiveView — GIMME-style dashboard integrated into APM chrome.

  Supports:
  - /showcase           → active project from config
  - /showcase/:project  → named project via push_patch (async URL update)
  - Iframe mode for migrated standalone showcases (priv/static/showcase/projects/:name/)
  - Fullscreen toggle (covers APM chrome, Esc to exit)
  """

  use ApmWeb, :live_view


  alias Apm.AgentRegistry
  alias Apm.AgUi.ActivityTracker
  alias Apm.ConfigLoader
  alias Apm.ShowcaseDataStore
  alias Apm.UpmStore

  # IPC event_type prefix patterns that trigger re-render
  @ipc_event_prefixes ["upm.", "formation.", "wave.", "version."]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:agents")
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:config")
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:upm")
      Phoenix.PubSub.subscribe(Apm.PubSub, "ag_ui:events")
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:showcase")
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:activity_log")
      Phoenix.PubSub.subscribe(Apm.PubSub, "ccem:ipc:events")

      :timer.send_interval(5_000, self(), :heartbeat_push)
    end

    config = safe_get_config()
    all_projects = Map.get(config, "projects", [])
    showcase_projects = ShowcaseDataStore.filter_showcase_projects(all_projects)

    socket =
      socket
      |> assign(:page_title, "Showcase")
      |> assign(:all_projects, all_projects)
      |> assign(:showcase_projects, ensure_ccem_in_list(showcase_projects))
      |> assign(:active_project, nil)
      |> assign(:showcase_data, %{})
      |> assign(:features, [])
      |> assign(:narratives, %{})
      |> assign(:slides, %{})
      |> assign(:design_system, %{})
      |> assign(:version, "7.0.0")
      |> assign(:activity_log, [])
      # Showcase mode: :engine (APM-integrated data) or :standalone (iframe/external)
      |> assign(:showcase_mode, :engine)
      |> assign(:standalone_projects, list_standalone_projects())
      |> assign(:standalone_url, nil)
      # Queryable tabs + diagrams (v2)
      |> assign(:tabs, [])
      |> assign(:diagrams, [])
      |> assign(:active_tab, nil)
      |> assign(:tab_data, %{})
      |> assign(:tab_query, "")

    {:ok, socket |> assign(:sidebar_collapsed, false)
     |> assign(:inspector_open, false)
     |> ApmWeb.Components.SidebarNav.assign_sidebar_nav_data()}
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
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav current_path="/showcase" />
      </:sidebar>
      <:main>

      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Header --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0 relative z-10">
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
            <%!-- Engine / Standalone mode toggle (US-120) --%>
            <div class="join">
              <button
                phx-click="switch_mode"
                phx-value-mode="engine"
                class={"join-item btn btn-xs #{if @showcase_mode == :engine, do: "btn-primary", else: "btn-ghost"}"}
              >
                <.icon name="hero-cpu-chip" class="size-3" />
                Engine
              </button>
              <button
                phx-click="switch_mode"
                phx-value-mode="standalone"
                class={"join-item btn btn-xs #{if @showcase_mode == :standalone, do: "btn-primary", else: "btn-ghost"}"}
              >
                <.icon name="hero-globe-alt" class="size-3" />
                Standalone
              </button>
            </div>
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

        <%!-- Queryable Tabs Bar (v2) — visible when project has tabs or diagrams --%>
        <div :if={length(@tabs) > 0 or length(@diagrams) > 0} class="bg-base-200 border-b border-base-300 px-4 py-1 flex items-center gap-2 flex-shrink-0">
          <%!-- Tab pills --%>
          <button
            :for={tab <- @tabs}
            phx-click="switch_tab"
            phx-value-tab={tab["id"]}
            class={"btn btn-xs #{if @active_tab == tab["id"], do: "btn-primary", else: "btn-ghost"}"}
          >
            {tab["label"] || tab["id"]}
          </button>

          <%!-- Diagrams pill --%>
          <button
            :if={length(@diagrams) > 0}
            phx-click="switch_tab"
            phx-value-tab="__diagrams__"
            class={"btn btn-xs #{if @active_tab == "__diagrams__", do: "btn-primary", else: "btn-ghost"} gap-1"}
          >
            <.icon name="hero-chart-bar-square" class="size-3" />
            Diagrams
            <span class="badge badge-xs">{length(@diagrams)}</span>
          </button>

          <%!-- Search (when a queryable tab is active) --%>
          <form :if={@active_tab && @active_tab != "__diagrams__"} phx-change="search_tab" class="ml-auto">
            <input
              type="text"
              name="query"
              value={@tab_query}
              placeholder="Search..."
              phx-debounce="200"
              class="input input-xs input-bordered w-48 bg-base-300"
            />
          </form>
        </div>

        <%!-- Tab Content Panel (v2) — shows when a tab is active instead of engine --%>
        <div :if={@active_tab && @active_tab != "__diagrams__"} class="flex-1 overflow-auto p-4 bg-base-300">
          <div class="max-w-5xl mx-auto">
            <% content = case @tab_data do
              {:ok, data} -> data
              {:error, _} -> %{"error" => "Failed to load tab data"}
              data when is_map(data) -> data
              _ -> %{}
            end %>
            <pre class="bg-base-200 p-4 rounded text-xs overflow-auto max-h-96">{Jason.encode!(content, pretty: true)}</pre>
          </div>
        </div>

        <%!-- Diagrams Panel (v2) — shows rendered diagrams --%>
        <div :if={@active_tab == "__diagrams__"} class="flex-1 overflow-auto p-4 bg-base-300">
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-4 max-w-6xl mx-auto">
            <div :for={diagram <- @diagrams} class="card bg-base-200 shadow-sm">
              <div class="card-body p-3">
                <h3 class="card-title text-sm font-mono">{diagram["id"]}</h3>
                <div class="badge badge-xs badge-ghost">{diagram["type"]}</div>
                <div
                  id={"diagram-#{diagram["id"]}"}
                  phx-hook="MermaidHook"
                  data-diagram-type={diagram["type"]}
                  data-diagram-content={diagram["content"]}
                  class="mt-2 overflow-auto bg-base-300 rounded p-2 min-h-[200px]"
                >
                  <div class="text-xs text-base-content/30 font-mono">rendering...</div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Standalone mode: iframe-based external showcases (US-120) --%>
        <div :if={@showcase_mode == :standalone} class="flex-1 overflow-hidden bg-base-300">
          <div :if={@standalone_url} class="h-full">
            <iframe src={@standalone_url} class="w-full h-full border-0" title="Standalone Showcase" />
          </div>
          <div :if={is_nil(@standalone_url)} class="h-full flex flex-col items-center justify-center p-8">
            <.icon name="hero-globe-alt" class="size-12 text-base-content/20 mb-4" />
            <h3 class="text-lg font-semibold text-base-content/60 mb-2">Standalone Showcases</h3>
            <p class="text-sm text-base-content/40 mb-6 text-center max-w-md">
              Select a project with a standalone showcase server, or projects with
              migrated static showcases in priv/static/showcase/projects/.
            </p>
            <div :if={@standalone_projects != []} class="grid grid-cols-2 gap-3 w-full max-w-lg">
              <button
                :for={sp <- @standalone_projects}
                phx-click="open_standalone"
                phx-value-project={sp.name}
                class="card bg-base-200 hover:bg-base-100 transition-colors cursor-pointer"
              >
                <div class="card-body p-4">
                  <h4 class="font-semibold text-sm">{sp.name}</h4>
                  <p class="text-xs text-base-content/50">{sp.source}</p>
                </div>
              </button>
            </div>
            <div :if={@standalone_projects == []} class="text-sm text-base-content/30">
              No standalone showcases found. Run <code>/showcase standalone start</code> to create one.
            </div>
          </div>
        </div>

        <%!-- Showcase container — ShowcaseHook mounts here; engine targets inner phx-update=ignore div --%>
        <div
          :if={@showcase_mode == :engine && (is_nil(@active_tab) || (@active_tab != "__diagrams__" && !Enum.any?(@tabs, fn t -> t["id"] == @active_tab end)))}
          id="showcase-container"
          phx-hook="ShowcaseHook"
          data-project={@active_project || "ccem"}
          data-version={@version}
          data-features={Jason.encode!(@features)}
          data-narratives={Jason.encode!(@narratives)}
          data-slides={Jason.encode!(@slides)}
          data-design-system={Jason.encode!(@design_system)}
          data-diagrams={Jason.encode!(strip_diagram_content(@diagrams))}
          data-tabs={Jason.encode!(strip_tab_data(@tabs))}
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
    <.wizard page="showcase" />
    <%!-- Showcase sync WebSocket bootstrap (v8.4.0) --%>
    <div
      id="showcase-sync"
      phx-hook="ShowcaseSyncHook"
      data-project={@active_project || "ccem"}
      class="hidden"
    ></div>
      </:main>
    </.page_layout>
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

  def handle_event("switch_tab", %{"tab" => tab_id}, socket) do
    tabs = socket.assigns.tabs

    tab_data = case Enum.find(tabs, fn t -> t["id"] == tab_id end) do
      %{"data" => data} -> data
      _ -> %{}
    end

    socket =
      socket
      |> assign(:active_tab, tab_id)
      |> assign(:tab_data, tab_data)
      |> assign(:tab_query, "")
      |> push_event("showcase:tab-changed", %{tab_id: tab_id, data: tab_data})

    {:noreply, socket}
  end

  def handle_event("search_tab", %{"query" => query}, socket) do
    project = socket.assigns.active_project
    active_tab = socket.assigns.active_tab

    filtered = if active_tab do
      ShowcaseDataStore.get_tab_data(project, active_tab, %{"search" => query})
    else
      %{}
    end

    socket =
      socket
      |> assign(:tab_query, query)
      |> assign(:tab_data, filtered)
      |> push_event("showcase:tab-filtered", %{tab_id: active_tab, data: filtered, query: query})

    {:noreply, socket}
  end

  def handle_event("switch_mode", %{"mode" => mode}, socket) do
    mode_atom = if mode == "standalone", do: :standalone, else: :engine
    {:noreply, assign(socket, :showcase_mode, mode_atom)}
  end

  def handle_event("open_standalone", %{"project" => project}, socket) do
    sp = Enum.find(socket.assigns.standalone_projects, &(&1.name == project))
    url = if sp, do: sp.url, else: nil
    {:noreply, assign(socket, :standalone_url, url)}
  end

  def handle_event("load_diagram", %{"id" => diagram_id}, socket) do
    diagrams = socket.assigns.diagrams

    case Enum.find(diagrams, fn d -> d["id"] == diagram_id end) do
      nil ->
        {:noreply, socket}

      diagram ->
        {:noreply, push_event(socket, "showcase:diagram-loaded", diagram)}
    end
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
     |> assign(:showcase_projects, ensure_ccem_in_list(showcase_projects))}
  end

  def handle_info({:showcase_data_reloaded, project, data}, socket) do
    if project == (socket.assigns.active_project || "ccem") do
      features = Map.get(data, "features", [])
      narratives = Map.get(data, "narratives", %{})
      slides = Map.get(data, "slides", %{})
      design_system = Map.get(data, "design_system", %{})
      version = Map.get(data, "version", "7.0.0") || "7.0.0"

      {:noreply,
       socket
       |> assign(:showcase_data, data)
       |> assign(:features, features)
       |> assign(:narratives, narratives)
       |> assign(:slides, slides)
       |> assign(:design_system, design_system)
       |> assign(:version, version)
       |> push_event("showcase:project-changed", %{
         project: project,
         version: version,
         features: features,
         narratives: narratives,
         slides: slides,
         designSystem: design_system,
         staticPath: static_showcase_path(project)
       })}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:ccem_ipc, event}, socket) do
    event_type = Map.get(event, "event_type", "")

    if ipc_event_matches?(event_type) do
      payload = Map.get(event, "payload", %{})

      {:noreply,
       push_event(socket, "showcase:ipc_event", %{
         event_type: event_type,
         payload: payload
       })}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private ---

  @spec ipc_event_matches?(String.t()) :: boolean()
  defp ipc_event_matches?(event_type) do
    Enum.any?(@ipc_event_prefixes, &String.starts_with?(event_type, &1))
  end

  defp load_project(project, socket) do
    showcase_data = ShowcaseDataStore.get_showcase_data(project)
    features = Map.get(showcase_data, "features", [])
    narratives = Map.get(showcase_data, "narratives", %{})
    slides = Map.get(showcase_data, "slides", %{})
    design_system = Map.get(showcase_data, "design_system", %{})
    diagrams = Map.get(showcase_data, "diagrams", [])
    tabs = Map.get(showcase_data, "tabs", [])
    version = Map.get(showcase_data, "version", "7.0.0") || "7.0.0"
    static_path = static_showcase_path(project)

    # Auto-select first tab if available
    first_tab = case tabs do
      [first | _] -> first["id"]
      _ -> nil
    end

    first_tab_data = if first_tab do
      case Enum.find(tabs, fn t -> t["id"] == first_tab end) do
        %{"data" => data} -> data
        _ -> %{}
      end
    else
      %{}
    end

    socket =
      socket
      |> assign(:active_project, project)
      |> assign(:showcase_data, showcase_data)
      |> assign(:features, features)
      |> assign(:narratives, narratives)
      |> assign(:slides, slides)
      |> assign(:design_system, design_system)
      |> assign(:diagrams, diagrams)
      |> assign(:tabs, tabs)
      |> assign(:active_tab, first_tab)
      |> assign(:tab_data, first_tab_data)
      |> assign(:tab_query, "")
      |> assign(:version, version)

    # Push project-changed with diagrams and tabs
    socket =
      push_event(socket, "showcase:project-changed", %{
        project: project,
        version: version,
        features: features,
        narratives: narratives,
        slides: slides,
        designSystem: design_system,
        diagrams: strip_diagram_content(diagrams),
        tabs: strip_tab_data(tabs),
        staticPath: static_path
      })

    {:noreply, socket}
  end


  defp strip_diagram_content(diagrams) do
    Enum.map(diagrams, fn d -> Map.drop(d, ["content"]) end)
  end

  defp strip_tab_data(tabs) do
    Enum.map(tabs, fn t -> Map.drop(t, ["data"]) end)
  end

  # Returns the static serve path if a migrated project showcase exists under
  # priv/static/showcase/projects/{name}/index.html, else empty string.
  defp static_showcase_path(nil), do: ""

  defp static_showcase_path(project) when is_binary(project) do
    static_file =
      Path.join([
        to_string(:code.priv_dir(:apm)),
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
    start = Application.get_env(:apm, :server_start_time, System.monotonic_time(:second))
    elapsed = System.monotonic_time(:second) - start
    hours = div(elapsed, 3600)
    minutes = div(rem(elapsed, 3600), 60)
    "#{hours}h #{minutes}m"
  end

  # Ensures the default CCEM showcase is always present in the project list.
  # Also deduplicates by name.
  defp ensure_ccem_in_list(projects) do
    names = MapSet.new(projects, fn p -> p["name"] end)

    base =
      if MapSet.member?(names, "ccem") do
        projects
      else
        [%{"name" => "ccem", "source" => "default"} | projects]
      end

    # Deduplicate by name, keeping first occurrence
    base
    |> Enum.uniq_by(fn p -> p["name"] end)
  end

  # Discover standalone showcases: static files in priv/ + any running showcase servers
  defp list_standalone_projects do
    static_dir = Path.join(to_string(:code.priv_dir(:apm)), "static/showcase/projects")

    static_projects =
      if File.dir?(static_dir) do
        static_dir
        |> File.ls!()
        |> Enum.filter(&File.dir?(Path.join(static_dir, &1)))
        |> Enum.map(fn name ->
          %{name: name, source: "static", url: "/showcase/projects/#{name}/index.html"}
        end)
      else
        []
      end

    # Check for showcase data directory (~/Developer/ccem/showcase/)
    showcase_dir = Path.expand("~/Developer/ccem/showcase/client")

    external =
      if File.dir?(showcase_dir) do
        [%{name: "ccem-standalone", source: "local server (port 8080)", url: "http://localhost:8080"}]
      else
        []
      end

    static_projects ++ external
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
