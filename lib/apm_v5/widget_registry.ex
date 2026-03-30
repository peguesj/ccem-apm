defmodule ApmV5.WidgetRegistry do
  @moduledoc """
  GenServer-backed ETS registry for dashboard widgets.

  Built-in widgets are registered on init. Plugins may call `register_widget/1`
  during their own init to add custom widgets to the palette.

  ## Widget Definition Schema

      %{
        id: String.t(),               # unique snake_case identifier
        name: String.t(),             # human display name
        description: String.t(),
        category: atom(),             # :monitoring | :formation | :auth | :workflow | :plugin | :custom
        source_module: atom(),        # GenServer or store providing data
        refresh_interval: integer() | nil,  # ms; nil = PubSub-driven
        min_width: integer(),         # grid columns (1-12)
        min_height: integer(),        # grid rows
        config_schema: map(),         # configurable options with types
        plugin: String.t() | nil,     # plugin_name if plugin-provided
        version: String.t()
      }

  ## Usage

      ApmV5.WidgetRegistry.list_widgets()
      ApmV5.WidgetRegistry.list_by_category(:monitoring)
      ApmV5.WidgetRegistry.get_widget("agent_fleet")
      ApmV5.WidgetRegistry.register_widget(%{id: "my_widget", ...})
  """

  use GenServer

  require Logger

  @table :widget_registry

  @type widget_definition :: %{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          category: atom(),
          source_module: atom(),
          refresh_interval: integer() | nil,
          min_width: integer(),
          min_height: integer(),
          config_schema: map(),
          plugin: String.t() | nil,
          version: String.t()
        }

  @builtin_widgets [
    %{
      id: "agent_fleet",
      name: "Agent Fleet",
      description: "Live agent count by status with formation summary and sparkline",
      category: :monitoring,
      source_module: ApmV5.AgentRegistry,
      refresh_interval: nil,
      min_width: 3,
      min_height: 2,
      config_schema: %{show_sparkline: "boolean", show_formations: "boolean"},
      plugin: nil,
      version: "1.0.0"
    },
    %{
      id: "formation_graph",
      name: "Formation Graph",
      description: "Live dependency graph of active formations and agents",
      category: :formation,
      source_module: ApmV5.FormationStore,
      refresh_interval: nil,
      min_width: 6,
      min_height: 4,
      config_schema: %{layout: "enum:graph_td,graph_lr,hierarchical,card_grid", max_depth: "integer"},
      plugin: nil,
      version: "1.0.0"
    },
    %{
      id: "pending_decisions",
      name: "Pending Decisions",
      description: "AgentLock pending authorization requests with inline Approve/Deny",
      category: :auth,
      source_module: ApmV5.Auth.PendingDecisions,
      refresh_interval: nil,
      min_width: 4,
      min_height: 3,
      config_schema: %{auto_expand: "boolean"},
      plugin: nil,
      version: "1.0.0"
    },
    %{
      id: "usage_summary",
      name: "Usage Summary",
      description: "Claude token usage, effort level, and per-project breakdown",
      category: :monitoring,
      source_module: ApmV5.ClaudeUsageStore,
      refresh_interval: 30_000,
      min_width: 3,
      min_height: 2,
      config_schema: %{show_breakdown: "boolean", time_window: "enum:1h,24h,7d"},
      plugin: nil,
      version: "1.0.0"
    },
    %{
      id: "background_tasks",
      name: "Background Tasks",
      description: "Running background tasks with status, runtime, and stop controls",
      category: :monitoring,
      source_module: ApmV5.BackgroundTasksStore,
      refresh_interval: nil,
      min_width: 4,
      min_height: 3,
      config_schema: %{show_completed: "boolean", max_rows: "integer"},
      plugin: nil,
      version: "1.0.0"
    },
    %{
      id: "plane_board",
      name: "Plane Board",
      description: "Plane PM Kanban summary — issues by state for CCEM project",
      category: :workflow,
      source_module: ApmV5.Plugins.PluginRegistry,
      refresh_interval: 120_000,
      min_width: 4,
      min_height: 3,
      config_schema: %{project_id: "string", show_cancelled: "boolean"},
      plugin: "plane",
      version: "1.0.0"
    },
    %{
      id: "notifications",
      name: "Notifications",
      description: "Recent APM notifications filterable by category",
      category: :monitoring,
      source_module: ApmV5.AgentRegistry,
      refresh_interval: nil,
      min_width: 3,
      min_height: 3,
      config_schema: %{max_items: "integer", category_filter: "string"},
      plugin: nil,
      version: "1.0.0"
    },
    %{
      id: "upm_workflow",
      name: "UPM Workflow",
      description: "Active UPM session with story progress and current wave",
      category: :workflow,
      source_module: ApmV5.UpmStore,
      refresh_interval: nil,
      min_width: 4,
      min_height: 3,
      config_schema: %{show_stories: "boolean", compact: "boolean"},
      plugin: nil,
      version: "1.0.0"
    },
    %{
      id: "port_status",
      name: "Port Status",
      description: "Active port assignments and conflict detection",
      category: :monitoring,
      source_module: ApmV5.PortManager,
      refresh_interval: 10_000,
      min_width: 3,
      min_height: 2,
      config_schema: %{show_conflicts_only: "boolean"},
      plugin: nil,
      version: "1.0.0"
    },
    %{
      id: "session_overview",
      name: "Session Overview",
      description: "Active Claude Code sessions with agent and port counts",
      category: :monitoring,
      source_module: ApmV5.SessionManager,
      refresh_interval: 30_000,
      min_width: 3,
      min_height: 2,
      config_schema: %{show_inactive: "boolean"},
      plugin: nil,
      version: "1.0.0"
    },
    %{
      id: "auth_audit",
      name: "Auth Audit Log",
      description: "Recent AgentLock authorization decisions with risk levels",
      category: :auth,
      source_module: ApmV5.Auth.AuthorizationGate,
      refresh_interval: nil,
      min_width: 5,
      min_height: 3,
      config_schema: %{max_entries: "integer", show_granted: "boolean", show_denied: "boolean"},
      plugin: nil,
      version: "1.0.0"
    },
    %{
      id: "skills_health",
      name: "Skills Health",
      description: "Skills registry health scores and fix recommendations",
      category: :monitoring,
      source_module: ApmV5.SkillsRegistryStore,
      refresh_interval: 60_000,
      min_width: 3,
      min_height: 2,
      config_schema: %{show_unhealthy_only: "boolean"},
      plugin: nil,
      version: "1.0.0"
    }
  ]

  # ── Public API ────────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a widget definition. Overwrites if id already exists."
  @spec register_widget(widget_definition()) :: :ok
  def register_widget(widget) when is_map(widget) do
    GenServer.call(__MODULE__, {:register_widget, widget})
  end

  @doc "List all registered widgets."
  @spec list_widgets() :: [widget_definition()]
  def list_widgets do
    :ets.tab2list(@table) |> Enum.map(fn {_id, widget} -> widget end)
  end

  @doc "List widgets filtered by category atom."
  @spec list_by_category(atom()) :: [widget_definition()]
  def list_by_category(category) do
    list_widgets() |> Enum.filter(&(&1.category == category))
  end

  @doc "Get a single widget by id string."
  @spec get_widget(String.t()) :: widget_definition() | nil
  def get_widget(id) do
    case :ets.lookup(@table, id) do
      [{^id, widget}] -> widget
      [] -> nil
    end
  end

  @doc "List all categories that have at least one widget."
  @spec list_categories() :: [atom()]
  def list_categories do
    list_widgets() |> Enum.map(& &1.category) |> Enum.uniq() |> Enum.sort()
  end

  # ── GenServer Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    register_builtins(table)
    load_plugin_widgets()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register_widget, widget}, _from, state) do
    :ets.insert(state.table, {widget.id, widget})
    {:reply, :ok, state}
  end

  # ── Private Helpers ───────────────────────────────────────────────────────────

  defp register_builtins(table) do
    for widget <- @builtin_widgets do
      :ets.insert(table, {widget.id, widget})
    end

    Logger.debug("[WidgetRegistry] Registered #{length(@builtin_widgets)} built-in widgets")
  end

  defp load_plugin_widgets do
    # Called after init — plugins may not be started yet, so we do a best-effort
    # scan via PluginRegistry if it's running, otherwise skip silently.
    case Process.whereis(ApmV5.Plugins.PluginRegistry) do
      nil ->
        :ok

      _pid ->
        try do
          plugins = ApmV5.Plugins.PluginRegistry.list_plugins()

          for plugin <- plugins do
            module = plugin[:module]

            if module && function_exported?(module, :dashboard_widgets, 0) do
              widgets = module.dashboard_widgets()

              for widget <- widgets do
                :ets.insert(@table, {widget.id, widget})
              end
            end
          end
        rescue
          _ -> :ok
        end
    end
  end
end
