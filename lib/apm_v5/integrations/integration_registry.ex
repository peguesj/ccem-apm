defmodule ApmV5.Integrations.IntegrationRegistry do
  @moduledoc """
  GenServer + ETS registry for APM integrations.

  Integrations are registered by module (must implement
  `ApmV5.Integrations.IntegrationBehaviour`). The registry stores integration
  metadata and delegates event calls to the module.

  ## ETS Table
  - Name: `:integration_registry`
  - Key: integration_name (String.t)
  - Value: `{module, metadata_map}`

  ## Default Integrations
  Default integrations are listed in `@default_integrations` and are
  registered automatically at startup. Additional integrations may be
  registered at runtime via `register/1`.
  """

  use GenServer
  require Logger

  @table :integration_registry

  @default_integrations [
    ApmV5.Integrations.Agentlock.AgentlockIntegration,
    ApmV5.Integrations.AgUi.AgUiIntegration,
    ApmV5.Integrations.Lvm.LvmIntegration,
    ApmV5.Integrations.ClaudeMem.ClaudeMemIntegration,
    ApmV5.Integrations.ClaudeFlow.ClaudeFlowIntegration,
    ApmV5.Integrations.ClaudeExpertise.ClaudeExpertiseIntegration,
    ApmV5.Integrations.Uat.UatIntegration,
    ApmV5.Integrations.RalphIntegration,
    ApmV5.Integrations.Worktree.WorktreeIntegration
  ]

  # ── Public API ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register an integration module. Must implement IntegrationBehaviour."
  @spec register(module()) :: :ok | {:error, term()}
  def register(module) when is_atom(module) do
    GenServer.call(__MODULE__, {:register, module})
  end

  @doc "List all registered integrations as metadata maps (module key excluded for JSON safety)."
  @spec list_integrations() :: [map()]
  def list_integrations do
    :ets.tab2list(@table)
    |> Enum.map(fn {_name, {_mod, meta}} -> Map.delete(meta, :module) end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Get a single integration's metadata by name (module key excluded for JSON safety)."
  @spec get_integration(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_integration(name) do
    case :ets.lookup(@table, name) do
      [{^name, {_mod, meta}}] -> {:ok, Map.delete(meta, :module)}
      [] -> {:error, :not_found}
    end
  end

  @doc "Re-register all default integrations. Useful after hot code reload."
  @spec reload_defaults() :: [:ok | {:error, term()}]
  def reload_defaults do
    GenServer.call(__MODULE__, :reload_defaults)
  end

  @doc """
  Returns all integrations whose `required_plugin/0` matches the given plugin name.
  Used by the plugin/integration symbiosis layer to enumerate integrations linked
  to a specific plugin.
  """
  @spec integrations_for_plugin(String.t()) :: [map()]
  def integrations_for_plugin(plugin_name) when is_binary(plugin_name) do
    list_integrations()
    |> Enum.filter(fn i -> i[:required_plugin] == plugin_name end)
  end

  @doc """
  Returns all integrations that target a given native APM feature atom.
  """
  @spec integrations_for_native_feature(atom()) :: [map()]
  def integrations_for_native_feature(feature) when is_atom(feature) do
    list_integrations()
    |> Enum.filter(fn i -> i[:target_native_feature] == feature end)
  end

  @doc "Invoke a named event on a registered integration."
  @spec call_integration_event(String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def call_integration_event(integration_name, event_type, payload) do
    case :ets.lookup(@table, integration_name) do
      [{^integration_name, {mod, _meta}}] ->
        try do
          mod.handle_event(event_type, payload, [])
        rescue
          e -> {:error, {:exception, Exception.message(e)}}
        end

      [] ->
        {:error, {:not_found, integration_name}}
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, read_concurrency: true])
    # Register defaults synchronously so they're available at first LiveView mount
    Enum.each(@default_integrations, &do_register/1)
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:register_defaults, state) do
    Enum.each(@default_integrations, &do_register/1)
    {:noreply, state}
  end

  @impl true
  def handle_call({:register, module}, _from, state) do
    {:reply, do_register(module), state}
  end

  @impl true
  def handle_call(:reload_defaults, _from, state) do
    results = Enum.map(@default_integrations, &do_register/1)
    {:reply, results, state}
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  @spec do_register(module()) :: :ok | {:error, term()}
  defp do_register(module) do
    # Ensure the module is loaded before checking exported functions.
    Code.ensure_loaded(module)

    with true <- function_exported?(module, :integration_name, 0),
         true <- function_exported?(module, :integration_description, 0),
         true <- function_exported?(module, :integration_version, 0),
         true <- function_exported?(module, :protocol, 0),
         true <- function_exported?(module, :connect, 1),
         true <- function_exported?(module, :disconnect, 0),
         true <- function_exported?(module, :status, 0),
         true <- function_exported?(module, :list_endpoints, 0),
         true <- function_exported?(module, :handle_event, 3),
         true <- function_exported?(module, :supervisor_children, 0) do
      name = module.integration_name()

      meta = %{
        name: name,
        description: module.integration_description(),
        version: module.integration_version(),
        protocol: module.protocol(),
        endpoints: module.list_endpoints(),
        status: safe_status(module),
        module: module,
        required_plugin: safe_optional(module, :required_plugin, 0, nil),
        target_native_feature: safe_optional(module, :target_native_feature, 0, nil),
        registered_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      :ets.insert(@table, {name, {module, meta}})
      Logger.info("[IntegrationRegistry] Registered integration: #{name} v#{meta.version}")
      :ok
    else
      false -> {:error, :invalid_integration_behaviour}
    end
  end

  @spec safe_status(module()) :: atom()
  defp safe_status(module) do
    try do
      module.status()
    rescue
      _ -> :disconnected
    end
  end

  @spec safe_optional(module(), atom(), non_neg_integer(), term()) :: term()
  defp safe_optional(module, fun, arity, default) do
    if function_exported?(module, fun, arity) do
      try do
        apply(module, fun, [])
      rescue
        _ -> default
      end
    else
      default
    end
  end
end
