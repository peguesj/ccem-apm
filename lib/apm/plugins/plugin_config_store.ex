defmodule Apm.Plugins.PluginConfigStore do
  @moduledoc """
  Global ETS-backed configuration store for plugin and integration settings.

  Stores per-plugin/integration config overrides that are merged with
  `default_config/0` at read time. Broadcasts changes via PubSub so
  LiveViews and other consumers can react to config updates.

  ## Type Hints

  Config schemas use the same string type hints as `Apm.WidgetRegistry`:

    - `"boolean"` — true/false
    - `"integer"` — numeric
    - `"string"` — free text
    - `"secret"` — masked in UI, excluded from public API responses
    - `"enum:val1,val2,val3"` — constrained choice

  ## Storage

  ETS table `:plugin_config_store` with keys:
    - `{:plugin, name}` → config map
    - `{:integration, name}` → config map
  """

  use GenServer

  require Logger

  @table :plugin_config_store
  @pubsub_topic "apm:plugin_config"

  # ── Client API ──────────────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Get resolved config for a plugin (defaults merged with overrides)."
  @spec get_config(:plugin | :integration, String.t()) :: map()
  def get_config(kind, name) when kind in [:plugin, :integration] do
    overrides =
      case :ets.lookup(@table, {kind, name}) do
        [{_, config}] -> config
        [] -> %{}
      end

    defaults = fetch_defaults(kind, name)
    Map.merge(defaults, overrides)
  end

  @doc "Get raw overrides only (no defaults merged)."
  @spec get_overrides(:plugin | :integration, String.t()) :: map()
  def get_overrides(kind, name) when kind in [:plugin, :integration] do
    case :ets.lookup(@table, {kind, name}) do
      [{_, config}] -> config
      [] -> %{}
    end
  end

  @doc "Get config schema for a plugin or integration."
  @spec get_schema(:plugin | :integration, String.t()) :: map()
  def get_schema(kind, name) when kind in [:plugin, :integration] do
    fetch_schema(kind, name)
  end

  @doc """
  Update config for a plugin or integration.
  Validates against the schema before persisting.
  Returns `{:ok, resolved_config}` or `{:error, reasons}`.
  """
  @spec put_config(:plugin | :integration, String.t(), map()) ::
          {:ok, map()} | {:error, [{atom(), String.t()}]}
  def put_config(kind, name, config) when kind in [:plugin, :integration] and is_map(config) do
    GenServer.call(__MODULE__, {:put_config, kind, name, config})
  end

  @doc "Reset config to defaults (remove all overrides)."
  @spec reset_config(:plugin | :integration, String.t()) :: :ok
  def reset_config(kind, name) when kind in [:plugin, :integration] do
    GenServer.call(__MODULE__, {:reset_config, kind, name})
  end

  @doc "List all stored configs of a given kind."
  @spec list_configs(:plugin | :integration) :: [{String.t(), map()}]
  def list_configs(kind) when kind in [:plugin, :integration] do
    :ets.tab2list(@table)
    |> Enum.filter(fn {{k, _name}, _config} -> k == kind end)
    |> Enum.map(fn {{_k, name}, config} -> {name, config} end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Logger.debug("[PluginConfigStore] ETS table #{@table} initialized")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put_config, kind, name, config}, _from, state) do
    schema = fetch_schema(kind, name)

    case validate_config(kind, name, config, schema) do
      {:ok, sanitized} ->
        :ets.insert(@table, {{kind, name}, sanitized})

        resolved = Map.merge(fetch_defaults(kind, name), sanitized)

        Phoenix.PubSub.broadcast(
          Apm.PubSub,
          @pubsub_topic,
          {:config_updated, kind, name, resolved}
        )

        Logger.debug("[PluginConfigStore] Updated #{kind}:#{name} config")
        {:reply, {:ok, resolved}, state}

      {:error, reasons} ->
        {:reply, {:error, reasons}, state}
    end
  end

  def handle_call({:reset_config, kind, name}, _from, state) do
    :ets.delete(@table, {kind, name})

    Phoenix.PubSub.broadcast(
      Apm.PubSub,
      @pubsub_topic,
      {:config_reset, kind, name}
    )

    {:reply, :ok, state}
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp fetch_schema(:plugin, name) do
    case Apm.Plugins.PluginRegistry.get_plugin_with_module(name) do
      {:ok, {mod, _meta}} ->
        if function_exported?(mod, :config_schema, 0), do: mod.config_schema(), else: %{}

      _ ->
        %{}
    end
  end

  defp fetch_schema(:integration, name) do
    case lookup_integration_module(name) do
      {:ok, mod} ->
        if function_exported?(mod, :config_schema, 0), do: mod.config_schema(), else: %{}

      _ ->
        %{}
    end
  end

  defp fetch_defaults(:plugin, name) do
    case Apm.Plugins.PluginRegistry.get_plugin_with_module(name) do
      {:ok, {mod, _meta}} ->
        if function_exported?(mod, :default_config, 0), do: mod.default_config(), else: %{}

      _ ->
        %{}
    end
  end

  defp fetch_defaults(:integration, name) do
    case lookup_integration_module(name) do
      {:ok, mod} ->
        if function_exported?(mod, :default_config, 0), do: mod.default_config(), else: %{}

      _ ->
        %{}
    end
  end

  defp lookup_integration_module(name) do
    case :ets.lookup(:integration_registry, name) do
      [{^name, {mod, _meta}}] -> {:ok, mod}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  defp validate_config(kind, name, config, schema) do
    # First try the module's own validate_config/1 if it exists
    case try_module_validation(kind, name, config) do
      {:ok, _} = ok ->
        ok

      :no_validator ->
        # Fall back to schema-based validation
        validate_against_schema(config, schema)

      {:error, _} = err ->
        err
    end
  end

  defp try_module_validation(:plugin, name, config) do
    case Apm.Plugins.PluginRegistry.get_plugin_with_module(name) do
      {:ok, {mod, _meta}} ->
        if function_exported?(mod, :validate_config, 1), do: mod.validate_config(config), else: :no_validator

      _ ->
        :no_validator
    end
  end

  defp try_module_validation(:integration, name, config) do
    case lookup_integration_module(name) do
      {:ok, mod} ->
        if function_exported?(mod, :validate_config, 1), do: mod.validate_config(config), else: :no_validator

      _ ->
        :no_validator
    end
  end

  @doc false
  def validate_against_schema(config, schema) when map_size(schema) == 0 do
    {:ok, config}
  end

  def validate_against_schema(config, schema) do
    schema_keys = MapSet.new(Map.keys(schema) |> Enum.map(&to_string/1))

    errors =
      Enum.reduce(config, [], fn {key, value}, acc ->
        key_str = to_string(key)

        unless MapSet.member?(schema_keys, key_str) do
          [{String.to_atom(key_str), "unknown config key"} | acc]
        else
          type_hint = Map.get(schema, key) || Map.get(schema, String.to_atom(key_str))
          case validate_value(value, type_hint) do
            :ok -> acc
            {:error, msg} -> [{String.to_atom(key_str), msg} | acc]
          end
        end
      end)

    if errors == [], do: {:ok, config}, else: {:error, Enum.reverse(errors)}
  end

  defp validate_value(_value, nil), do: :ok
  defp validate_value(value, "boolean") when is_boolean(value), do: :ok
  defp validate_value(_value, "boolean"), do: {:error, "must be a boolean"}
  defp validate_value(value, "integer") when is_integer(value), do: :ok
  defp validate_value(_value, "integer"), do: {:error, "must be an integer"}
  defp validate_value(value, "string") when is_binary(value), do: :ok
  defp validate_value(_value, "string"), do: {:error, "must be a string"}
  defp validate_value(value, "secret") when is_binary(value), do: :ok
  defp validate_value(_value, "secret"), do: {:error, "must be a string"}

  defp validate_value(value, "enum:" <> opts) when is_binary(value) do
    allowed = String.split(opts, ",", trim: true)
    if value in allowed, do: :ok, else: {:error, "must be one of: #{opts}"}
  end

  defp validate_value(_value, "enum:" <> _opts), do: {:error, "must be a string"}
  defp validate_value(_value, _type), do: :ok
end
