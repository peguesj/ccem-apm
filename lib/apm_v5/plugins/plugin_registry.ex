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

  @doc "List all registered plugins as metadata maps."
  @spec list_plugins() :: [map()]
  def list_plugins do
    :ets.tab2list(@table)
    |> Enum.map(fn {_name, {_mod, meta}} -> meta end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Get a single plugin's metadata by name."
  @spec get_plugin(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_plugin(name) do
    case :ets.lookup(@table, name) do
      [{^name, {_mod, meta}}] -> {:ok, meta}
      [] -> {:error, :not_found}
    end
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

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, module}, _from, state) do
    result =
      with true <- function_exported?(module, :plugin_name, 0),
           true <- function_exported?(module, :plugin_description, 0),
           true <- function_exported?(module, :plugin_version, 0),
           true <- function_exported?(module, :list_endpoints, 0),
           true <- function_exported?(module, :handle_action, 3) do
        name = module.plugin_name()

        meta = %{
          name: name,
          description: module.plugin_description(),
          version: module.plugin_version(),
          endpoints: module.list_endpoints(),
          module: module,
          registered_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        :ets.insert(@table, {name, {module, meta}})
        Logger.info("[PluginRegistry] Registered plugin: #{name} v#{meta.version}")
        :ok
      else
        false -> {:error, :invalid_plugin_behaviour}
      end

    {:reply, result, state}
  end
end
