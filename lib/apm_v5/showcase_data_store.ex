defmodule ApmV5.ShowcaseDataStore do
  @moduledoc """
  GenServer that loads per-project showcase data from disk.
  Provides feature lists, narratives, design system, and redaction rules
  for the Showcase LiveView. ETS-cached, per-project keyed.
  """

  use GenServer

  @default_showcase_path Path.expand("~/Developer/ccem/showcase/data")

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns showcase data for a project. Falls back to default CCEM showcase data."
  @spec get_showcase_data(String.t() | nil) :: map()
  def get_showcase_data(project_name) do
    GenServer.call(__MODULE__, {:get_data, project_name || "ccem"})
  end

  @doc "Reloads showcase data for a project from disk."
  @spec reload(String.t() | nil) :: :ok
  def reload(project_name \\ nil) do
    GenServer.call(__MODULE__, {:reload, project_name || "ccem"})
  end

  @doc "Returns the list of features for a project."
  @spec get_features(String.t() | nil) :: list()
  def get_features(project_name) do
    data = get_showcase_data(project_name)
    Map.get(data, "features", [])
  end

  @doc """
  Returns true if the given project map has a usable showcase.
  Checks (in order):
    1. project has `showcase_data_path` pointing to an existing directory
    2. project has `project_root` and `project_root/showcase/data/` exists
    3. project has `project_root` and `project_root/showcase/client/showcase.js` exists (standalone)
  """
  @spec has_showcase?(map()) :: boolean()
  def has_showcase?(%{"showcase_data_path" => path}) when is_binary(path) and path != "" do
    File.dir?(Path.expand(path))
  end

  def has_showcase?(%{"project_root" => root}) when is_binary(root) and root != "" do
    expanded = Path.expand(root)
    File.dir?(Path.join(expanded, "showcase/data")) or
      File.exists?(Path.join(expanded, "showcase/client/showcase.js"))
  end

  def has_showcase?(_), do: false

  @doc "Filters a list of project maps to only those that have showcase data."
  @spec filter_showcase_projects(list()) :: list()
  def filter_showcase_projects(projects) when is_list(projects) do
    Enum.filter(projects, &has_showcase?/1)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(:showcase_data, [:set, :protected, read_concurrency: true])
    # Pre-load default CCEM showcase data
    data = load_showcase_data(@default_showcase_path)
    :ets.insert(table, {"ccem", data})
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:get_data, project_name}, _from, state) do
    data =
      case :ets.lookup(state.table, project_name) do
        [{^project_name, cached}] ->
          cached

        [] ->
          # Try to find project-specific showcase data
          showcase_path = resolve_showcase_path(project_name)
          loaded = load_showcase_data(showcase_path)
          :ets.insert(state.table, {project_name, loaded})
          loaded
      end

    {:reply, data, state}
  end

  def handle_call({:reload, project_name}, _from, state) do
    showcase_path =
      if project_name == "ccem",
        do: @default_showcase_path,
        else: resolve_showcase_path(project_name)

    data = load_showcase_data(showcase_path)
    :ets.insert(state.table, {project_name, data})

    Phoenix.PubSub.broadcast(
      ApmV5.PubSub,
      "apm:showcase",
      {:showcase_data_reloaded, project_name, data}
    )

    {:reply, :ok, state}
  end

  # --- Private ---

  defp resolve_showcase_path(project_name) do
    # Check if the project config specifies a showcase_data_path
    case ApmV5.ConfigLoader.get_project(project_name) do
      %{"showcase_data_path" => path} when is_binary(path) and path != "" ->
        Path.expand(path)

      %{"project_root" => root} when is_binary(root) and root != "" ->
        Path.join(Path.expand(root), "showcase/data")

      _ ->
        @default_showcase_path
    end
  end

  defp load_showcase_data(path) do
    %{
      "features" => load_json(Path.join(path, "features.json"), default_features()),
      "narratives" => load_json(Path.join(path, "narrative-content.json"), %{}),
      "design_system" => load_json(Path.join(path, "diagram-design-system.json"), %{}),
      "redaction_rules" => load_json(Path.join(path, "redaction-rules.json"), %{}),
      "speaker_notes" => load_json(Path.join(path, "speaker-notes.json"), %{}),
      "slides" => load_json(Path.join(path, "slides.json"), %{}),
      "version" => "5.5.0",
      "path" => path
    }
  end

  defp load_json(file_path, default) do
    case File.read(file_path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, data} -> data
          {:error, _} -> default
        end

      {:error, _} ->
        default
    end
  end

  defp default_features do
    # Inline default features matching showcase.js FEATURES constant
    [
      %{"id" => "US-001", "wave" => 1, "title" => "AG-UI Protocol", "description" => "30 typed event categories via ag_ui_ex Hex package. SSE transport, compile-time constants."},
      %{"id" => "US-002", "wave" => 1, "title" => "Event Router", "description" => "Central dispatch: routes AG-UI events to AgentRegistry, FormationStore, Dashboard, Metrics."},
      %{"id" => "US-003", "wave" => 1, "title" => "Event Stream", "description" => "Emit and retrieve events. PubSub broadcast to all subscribers. Time-ordered ETS storage."},
      %{"id" => "US-004", "wave" => 1, "title" => "Hook Bridge", "description" => "Translates legacy register/heartbeat/notify into AG-UI event types. Zero-config backward compat."},
      %{"id" => "US-005", "wave" => 1, "title" => "State Manager", "description" => "Per-agent state with versioning. Simplified JSON Patch. ETS-backed."},
      %{"id" => "US-006", "wave" => 2, "title" => "Agent Registry", "description" => "Lifecycle tracking for all agents. Squadron/swarm/cluster hierarchy. Fire-and-forget registration."},
      %{"id" => "US-007", "wave" => 2, "title" => "Formation Model", "description" => "Hierarchical agent coordination. Squadrons > Swarms > Clusters > Agents."},
      %{"id" => "US-008", "wave" => 2, "title" => "Metrics Collector", "description" => "Per-agent, per-project token economics. 12 x 5-min buckets, time-series."},
      %{"id" => "US-009", "wave" => 2, "title" => "Chat Store", "description" => "Scoped message persistence. AG-UI TEXT_MESSAGE integration. PubSub real-time."},
      %{"id" => "US-010", "wave" => 3, "title" => "19+ LiveView Dashboards", "description" => "Real-time Phoenix LiveView pages: agents, formations, analytics, health, tasks, scanner, actions, skills, notifications."},
      %{"id" => "US-011", "wave" => 3, "title" => "Sidebar Navigation", "description" => "Unified sidebar across all views. Active page highlighting, icon labels."},
      %{"id" => "US-012", "wave" => 3, "title" => "Notification Panel", "description" => "Tabbed categories with toast overlays. Read/unread."},
      %{"id" => "US-013", "wave" => 3, "title" => "Health Check System", "description" => "HealthCheckRunner with 15-second refresh. Overall status badge."},
      %{"id" => "US-014", "wave" => 3, "title" => "AG-UI Dashboard", "description" => "Live AG-UI event viewer. State inspector. Protocol stats. SSE streaming."},
      %{"id" => "US-015", "wave" => 3, "title" => "Conversation Monitor", "description" => "Real-time conversation tracking across scopes. Message history viewer."},
      %{"id" => "US-016", "wave" => 4, "title" => "CCEMAgent", "description" => "Native macOS menubar companion. Swift/AppKit. Telemetry charts, task management, start/stop APM."},
      %{"id" => "US-017", "wave" => 4, "title" => "Skill Health Monitor", "description" => "SkillsRegistryStore with health scoring. Audit engine."},
      %{"id" => "US-018", "wave" => 4, "title" => "Project Scanner", "description" => "Auto-discovery of projects, stacks, ports, hooks, MCPs, CLAUDE.md sections."},
      %{"id" => "US-019", "wave" => 4, "title" => "Background Task Manager", "description" => "Track Claude Code background tasks. Logs, stop, delete. 5s auto-refresh."},
      %{"id" => "US-020", "wave" => 4, "title" => "Action Engine", "description" => "4-action catalog: update_hooks, add_memory_pointer, backfill_apm_config, analyze_project."},
      %{"id" => "US-021", "wave" => 5, "title" => "UAT Testing Panel", "description" => "14 test cases across 6 categories. Live in-browser AG-UI subsystem exerciser."},
      %{"id" => "US-022", "wave" => 5, "title" => "Showcase Generator", "description" => "IP-safe architecture diagrams. C4 abstraction. GIMME-style live dashboard with roadmap."},
      %{"id" => "US-023", "wave" => 5, "title" => "Cross-Platform Installer", "description" => "Modular install.sh with libs: ui, detect, deps, build, hooks, service."},
      %{"id" => "US-024", "wave" => 5, "title" => "UPM Orchestration", "description" => "End-to-end: plan > build > verify > ship. Formation deployment. Plane PM sync."},
      %{"id" => "US-025", "wave" => 5, "title" => "OpenAPI 3.0.3 Spec", "description" => "56 endpoints across 21 categories. Scalar interactive docs at /api/docs."}
    ]
  end
end
