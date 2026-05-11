defmodule ApmV5.Plugins.PluginRegistry do
  @moduledoc """
  GenServer + ETS registry for APM plugins.

  Plugins are registered by module (must implement `ApmV5.Plugins.PluginBehaviour`).
  The registry stores plugin metadata and delegates action calls to the module.

  ## ETS Table
  - Name: `:plugin_registry`
  - Key: plugin_name (String.t)
  - Value: `{module, metadata_map}`
  """

  use GenServer
  require Logger

  @table :plugin_registry

  # ── Public API ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a plugin module. Must implement PluginBehaviour."
  @spec register_plugin(module()) :: :ok | {:error, term()}
  def register_plugin(module) when is_atom(module) do
    GenServer.call(__MODULE__, {:register, module})
  end

  @doc "List all registered plugins as metadata maps (module key excluded for JSON safety)."
  @spec list_plugins() :: [map()]
  def list_plugins do
    :ets.tab2list(@table)
    |> Enum.map(fn {_name, {_mod, meta}} -> Map.delete(meta, :module) end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "List registered plugins filtered by scope (:apm, :ccem, or :claude_code)."
  @spec list_plugins_by_scope(atom()) :: [map()]
  def list_plugins_by_scope(scope) when is_atom(scope) do
    list_plugins() |> Enum.filter(&(&1.scope == scope))
  end

  @doc "Get a single plugin's metadata by name (module key excluded for JSON safety)."
  @spec get_plugin(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_plugin(name) do
    case :ets.lookup(@table, name) do
      [{^name, {_mod, meta}}] -> {:ok, Map.delete(meta, :module)}
      [] -> {:error, :not_found}
    end
  end

  @doc "Get a single plugin's metadata including the module. Returns `{:ok, {module, meta}}` or `{:error, :not_found}`."
  @spec get_plugin_with_module(String.t()) :: {:ok, {module(), map()}} | {:error, :not_found}
  def get_plugin_with_module(name) do
    case :ets.lookup(@table, name) do
      [{^name, {mod, meta}}] -> {:ok, {mod, meta}}
      [] -> {:error, :not_found}
    end
  end

  @doc "Find a plugin by slug (dash-separated, case-insensitive). Tries exact name, then dash→underscore, then substring match."
  @spec find_plugin_by_slug(String.t()) :: {:ok, {module(), map()}} | {:error, :not_found}
  def find_plugin_by_slug(slug) do
    # Try exact match first
    case get_plugin_with_module(slug) do
      {:ok, _} = hit -> hit
      _ ->
        # Try underscore variant (sidebar generates dashes from underscores)
        underscore_name = String.replace(slug, "-", "_")
        case get_plugin_with_module(underscore_name) do
          {:ok, _} = hit -> hit
          _ ->
            # Fuzzy: find plugin whose name matches slug when both are normalized
            normalized = String.downcase(String.replace(slug, "-", "_"))
            all = :ets.tab2list(@table)
            case Enum.find(all, fn {name, _} -> String.downcase(name) == normalized end) do
              {_name, {mod, meta}} -> {:ok, {mod, meta}}
              nil -> {:error, :not_found}
            end
        end
    end
  end

  @doc "Check if a plugin declares an orchestration topology."
  @spec topology_declared?(String.t()) :: boolean()
  def topology_declared?(plugin_name) do
    case :ets.lookup(@table, plugin_name) do
      [{^plugin_name, {mod, _meta}}] ->
        Code.ensure_loaded(mod)
        function_exported?(mod, :orchestration_topology, 0) and mod.orchestration_topology() != nil

      _ ->
        false
    end
  end

  @doc "Re-register all default plugins. Useful after hot code reload."
  @spec reload_defaults() :: [:ok | {:error, term()}]
  def reload_defaults do
    GenServer.call(__MODULE__, :reload_defaults)
  end

  @doc "Invoke an action on a registered plugin."
  @spec call_plugin_action(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call_plugin_action(plugin_name, action, params) do
    case :ets.lookup(@table, plugin_name) do
      [{^plugin_name, {mod, _meta}}] ->
        try do
          mod.handle_action(action, params, [])
        rescue
          e -> {:error, {:exception, Exception.message(e)}}
        end

      [] ->
        {:error, {:not_found, plugin_name}}
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────────

  @default_plugins [
    ApmV5.Plugins.Plane.PlanePlugin,
    ApmV5.Plugins.Ralph.RalphPlugin,
    ApmV5.Plugins.Formations.FormationsPlugin,
    ApmV5.Plugins.Uat.UatPlugin,
    ApmV5.Plugins.Skills.SkillsPlugin,
    ApmV5.Plugins.Ports.PortsPlugin,
    ApmV5.Plugins.Usage.UsagePlugin,
    ApmV5.Plugins.Devops.DevopsPlugin,
    ApmV5.Plugins.Alerting.AlertingPlugin,
    ApmV5.Plugins.SimpleAgents.SimpleAgentsPlugin,
    ApmV5.Plugins.ClaudeCode.ClaudeCodePlugin,
    ApmV5.Plugins.Lvm.ClaudePlatformLvmPlugin,
    ApmV5.Plugins.Mirofish.MirofishPlugin,
    ApmV5.Plugins.SkillDrift.SkillDriftPlugin,
    ApmV5.Plugins.Orchestration.OrchestrationPlugin,
    ApmV5.Plugins.Memory.MemoryPlugin,
    ApmV5.Plugins.Worktree.WorktreePlugin,
    ApmV5.Plugins.Harness.HarnessPlugin,
    ApmV5.Plugins.OpenDesign.OpenDesignPlugin,
    ApmV5.Plugins.Composio.ComposioPlugin,
    ApmV5.Plugins.Builder.BuilderPlugin
  ]

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, read_concurrency: true])
    # Register bundled plugins synchronously so they're available immediately
    Enum.each(@default_plugins, &do_register/1)
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:register_defaults, state) do
    Enum.each(@default_plugins, &do_register/1)
    {:noreply, state}
  end

  @impl true
  def handle_call({:register, module}, _from, state) do
    {:reply, do_register(module), state}
  end

  @impl true
  def handle_call(:reload_defaults, _from, state) do
    results = Enum.map(@default_plugins, &do_register/1)
    {:reply, results, state}
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp do_register(module) do
    # Ensure the module is loaded before checking exported functions,
    # since function_exported?/3 returns false for unloaded modules.
    Code.ensure_loaded(module)

    with true <- function_exported?(module, :plugin_name, 0),
         true <- function_exported?(module, :plugin_description, 0),
         true <- function_exported?(module, :plugin_version, 0),
         true <- function_exported?(module, :list_endpoints, 0),
         true <- function_exported?(module, :handle_action, 3) do
      name = module.plugin_name()

      integrations =
        if function_exported?(module, :plugin_integrations, 0) do
          try do
            module.plugin_integrations()
          rescue
            _ -> []
          end
        else
          []
        end

      scope =
        if function_exported?(module, :plugin_scope, 0), do: module.plugin_scope(), else: :apm

      config_schema =
        if function_exported?(module, :config_schema, 0), do: module.config_schema(), else: %{}

      default_config =
        if function_exported?(module, :default_config, 0), do: module.default_config(), else: %{}

      meta = %{
        name: name,
        description: module.plugin_description(),
        version: module.plugin_version(),
        endpoints: module.list_endpoints(),
        integration_modules: integrations,
        scope: scope,
        config_schema: config_schema,
        default_config: default_config,
        module: module,
        registered_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      :ets.insert(@table, {name, {module, meta}})
      Logger.info("[PluginRegistry] Registered plugin: #{name} v#{meta.version}")
      :ok
    else
      false -> {:error, :invalid_plugin_behaviour}
    end
  end
end
