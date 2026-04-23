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
        default_config: map(),        # default values matching config_schema keys
        plugin: String.t() | nil,     # plugin_name if plugin-provided
        version: String.t(),
        editable: boolean(),          # whether users can edit widget config inline
        pinnable: boolean(),          # whether this widget can be pinned as a scope source
        supported_scopes: [String.t()], # scopes this widget supports: "global","project","formation","agent"
        display_order: integer()      # default display order in palette (lower = earlier)
      }

  ## Usage

      ApmV5.WidgetRegistry.list_widgets()
      ApmV5.WidgetRegistry.list_by_category(:monitoring)
      ApmV5.WidgetRegistry.get_widget("agent_fleet")
      ApmV5.WidgetRegistry.register_widget(%{id: "my_widget", ...})
      ApmV5.WidgetRegistry.update_widget_config("agent_fleet", %{show_sparkline: false})
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
          default_config: map(),
          plugin: String.t() | nil,
          version: String.t(),
          editable: boolean(),
          pinnable: boolean(),
          supported_scopes: [String.t()],
          display_order: integer()
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
      default_config: %{show_sparkline: true, show_formations: true},
      plugin: nil,
      version: "1.0.0",
      editable: true,
      pinnable: false,
      supported_scopes: ["global", "project"],
      display_order: 1
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
      default_config: %{layout: "graph_td", max_depth: 5},
      plugin: nil,
      version: "1.0.0",
      editable: true,
      pinnable: false,
      supported_scopes: ["global", "project", "formation"],
      display_order: 2
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
      default_config: %{auto_expand: true},
      plugin: nil,
      version: "1.0.0",
      editable: true,
      pinnable: false,
      supported_scopes: ["global", "project"],
      display_order: 3
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
      default_config: %{show_breakdown: true, time_window: "24h"},
      plugin: nil,
      version: "1.0.0",
      editable: true,
      pinnable: false,
      supported_scopes: ["global", "project"],
      display_order: 4
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
      default_config: %{show_completed: false, max_rows: 10},
      plugin: nil,
      version: "1.0.0",
      editable: true,
      pinnable: false,
      supported_scopes: ["global", "project"],
      display_order: 5
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
      default_config: %{project_id: "", show_cancelled: false},
      plugin: "plane",
      version: "1.0.0",
      editable: true,
      pinnable: false,
      supported_scopes: ["global", "project"],
      display_order: 6
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
      default_config: %{max_items: 20, category_filter: ""},
      plugin: nil,
      version: "1.0.0",
      editable: true,
      pinnable: false,
      supported_scopes: ["global", "project"],
      display_order: 7
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
      default_config: %{show_stories: true, compact: false},
      plugin: nil,
      version: "1.0.0",
      editable: true,
      pinnable: false,
      supported_scopes: ["global", "project"],
      display_order: 8
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
      default_config: %{show_conflicts_only: false},
      plugin: nil,
      version: "1.0.0",
      editable: true,
      pinnable: false,
      supported_scopes: ["global"],
      display_order: 9
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
      default_config: %{show_inactive: false},
      plugin: nil,
      version: "1.0.0",
      editable: true,
      pinnable: false,
      supported_scopes: ["global", "project"],
      display_order: 10
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
      default_config: %{max_entries: 50, show_granted: true, show_denied: true},
      plugin: nil,
      version: "1.0.0",
      editable: true,
      pinnable: false,
      supported_scopes: ["global", "project"],
      display_order: 11
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
      default_config: %{show_unhealthy_only: false},
      plugin: nil,
      version: "1.0.0",
      editable: true,
      pinnable: false,
      supported_scopes: ["global"],
      display_order: 12
    },
    %{
      id: "projects",
      name: "Projects",
      description: "Active projects list with session/agent counts — pin to scope all widgets to a project",
      category: :monitoring,
      source_module: ApmV5.ProjectStore,
      refresh_interval: nil,
      min_width: 3,
      min_height: 3,
      config_schema: %{show_inactive: "boolean", compact: "boolean"},
      default_config: %{show_inactive: false, compact: false},
      plugin: nil,
      version: "1.0.0",
      editable: true,
      pinnable: true,
      supported_scopes: ["global", "project"],
      display_order: 0
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

  @doc "List widgets that support a given scope string."
  @spec list_by_scope(String.t()) :: [widget_definition()]
  def list_by_scope(scope) when is_binary(scope) do
    list_widgets() |> Enum.filter(&(scope in &1.supported_scopes))
  end

  @doc "List widgets that can be pinned as scope sources."
  @spec list_pinnable() :: [widget_definition()]
  def list_pinnable do
    list_widgets() |> Enum.filter(& &1.pinnable)
  end

  @doc """
  Merge config overrides into a widget's default_config.
  Returns the merged config map (does not persist to ETS — use WidgetConfigStore for persistence).
  """
  @spec resolve_config(String.t(), map()) :: map()
  def resolve_config(widget_id, overrides \\ %{}) when is_binary(widget_id) and is_map(overrides) do
    case get_widget(widget_id) do
      nil -> overrides
      widget -> Map.merge(widget.default_config, overrides)
    end
  end

  @doc """
  Update a widget definition's default_config in ETS.
  Useful for plugins to set their own defaults after registration.
  """
  @spec update_widget_config(String.t(), map()) :: :ok | {:error, :not_found}
  def update_widget_config(widget_id, config_overrides)
      when is_binary(widget_id) and is_map(config_overrides) do
    GenServer.call(__MODULE__, {:update_widget_config, widget_id, config_overrides})
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
    widget_with_defaults = ensure_new_fields(widget)
    :ets.insert(state.table, {widget_with_defaults.id, widget_with_defaults})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update_widget_config, widget_id, config_overrides}, _from, state) do
    case :ets.lookup(state.table, widget_id) do
      [{^widget_id, widget}] ->
        updated = Map.update(widget, :default_config, config_overrides, &Map.merge(&1, config_overrides))
        :ets.insert(state.table, {widget_id, updated})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # ── Private Helpers ───────────────────────────────────────────────────────────

  defp register_builtins(table) do
    for widget <- @builtin_widgets do
      :ets.insert(table, {widget.id, ensure_new_fields(widget)})
    end

    Logger.debug("[WidgetRegistry] Registered #{length(@builtin_widgets)} built-in widgets")
  end

  # Ensures any widget (including legacy plugin widgets) has all v2 fields with safe defaults.
  defp ensure_new_fields(widget) do
    widget
    |> Map.put_new(:editable, true)
    |> Map.put_new(:pinnable, false)
    |> Map.put_new(:supported_scopes, ["global"])
    |> Map.put_new(:default_config, %{})
    |> Map.put_new(:display_order, 99)
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
