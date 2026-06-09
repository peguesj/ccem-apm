defmodule Apm.Plugins.Memory.MemoryPlugin do
  @moduledoc """
  APM Plugin adapter for the claude-mem memory system.

  Bridges the MemoryClientBridge HTTP/SQLite worker and the ObservationCache
  ETS layer into the APM plugin framework, exposing five actions for
  observation browsing, semantic search, timeline queries, and health checks.
  """

  @behaviour Apm.Plugins.PluginBehaviour

  alias Apm.Plugins.Memory.FederationRouter
  alias Apm.Plugins.Memory.MemoryClientBridge
  alias Apm.Plugins.Memory.ObservationCache

  require Logger

  @plugin_version "1.0.0"

  @impl true
  @spec plugin_name() :: String.t()
  def plugin_name, do: "memory"

  @impl true
  @spec plugin_description() :: String.t()
  def plugin_description,
    do:
      "Claude-Mem integration — observation browsing, semantic search, timeline, and conversation correlation"

  @impl true
  @spec plugin_version() :: String.t()
  def plugin_version, do: @plugin_version

  @impl true
  @spec plugin_scope() :: :memory
  def plugin_scope, do: :memory

  @impl true
  def config_schema do
    %{
      observation_ttl_ms: "integer",
      max_cache_size: "integer",
      auto_correlate: "boolean",
      sqlite_fallback: "boolean"
    }
  end

  @impl true
  def default_config do
    %{
      observation_ttl_ms: 300_000,
      max_cache_size: 1000,
      auto_correlate: true,
      sqlite_fallback: true
    }
  end

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{
        action: "list_observations",
        description: "List cached observations with optional filters",
        params: %{limit: "integer (optional)", offset: "integer (optional)"}
      },
      %{
        action: "search_observations",
        description: "Semantic search across observations; falls back to ETS substring match",
        params: %{query: "string (required)"}
      },
      %{
        action: "get_observation",
        description: "Get single observation by ID",
        params: %{id: "string (required)"}
      },
      %{
        action: "timeline",
        description: "Observations in date range via claude-mem worker",
        params: %{
          from: "ISO8601 datetime string (optional)",
          to: "ISO8601 datetime string (optional)"
        }
      },
      %{
        action: "health_check",
        description: "Claude-mem worker reachability status",
        params: %{}
      },
      %{
        action: "route_query",
        description:
          "Federated fanout search across claude_mem, viki, and (future) serena sources",
        params: %{
          query: "string (required)",
          sources: "list of atoms — [:claude_mem, :viki, :serena] (optional)",
          top_n: "integer — max results to return (optional, default 20)",
          timeout_ms: "integer — per-source timeout in ms (optional, default 500)"
        }
      }
    ]
  end

  @impl true
  @spec handle_action(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}

  def handle_action("list_observations", params, _opts) do
    opts =
      []
      |> maybe_put_opt(:limit, Map.get(params, "limit") || Map.get(params, :limit))
      |> maybe_put_opt(:offset, Map.get(params, "offset") || Map.get(params, :offset))

    cached = ObservationCache.list(opts)

    if cached == [] do
      # Cache empty — fetch from bridge and populate cache
      case MemoryClientBridge.timeline() do
        {:ok, observations} when observations != [] ->
          ObservationCache.refresh(observations)
          limited = apply_list_opts(observations, opts)
          {:ok, %{observations: limited, count: length(limited), source: :bridge}}

        _ ->
          {:ok, %{observations: [], count: 0, source: :cache}}
      end
    else
      {:ok, %{observations: cached, count: length(cached), source: :cache}}
    end
  end

  def handle_action("search_observations", params, _opts) do
    query = Map.get(params, "query") || Map.get(params, :query)

    if is_binary(query) and byte_size(query) > 0 do
      case MemoryClientBridge.search(query) do
        {:ok, results} ->
          {:ok, %{results: results, count: length(results), source: :bridge}}

        {:error, _reason} ->
          results = ObservationCache.search(query)
          {:ok, %{results: results, count: length(results), source: :cache}}
      end
    else
      {:error, {:invalid_params, "query must be a non-empty string"}}
    end
  end

  def handle_action("get_observation", params, _opts) do
    id = Map.get(params, "id") || Map.get(params, :id)

    if is_binary(id) do
      case ObservationCache.get(id) do
        nil ->
          case MemoryClientBridge.get_observations([id]) do
            {:ok, [obs | _]} -> {:ok, %{observation: obs, source: :bridge}}
            {:ok, []} -> {:error, {:not_found, id}}
            {:error, reason} -> {:error, reason}
          end

        observation ->
          {:ok, %{observation: observation, source: :cache}}
      end
    else
      {:error, {:invalid_params, "id must be a string"}}
    end
  end

  def handle_action("timeline", params, _opts) do
    opts =
      []
      |> maybe_put_datetime_opt(:from, Map.get(params, "from") || Map.get(params, :from))
      |> maybe_put_datetime_opt(:to, Map.get(params, "to") || Map.get(params, :to))

    case MemoryClientBridge.timeline(opts) do
      {:ok, observations} ->
        {:ok, %{observations: observations, count: length(observations)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_action("health_check", _params, _opts) do
    case MemoryClientBridge.health_check() do
      :ok ->
        {:ok, %{status: :ok, reachable: true}}

      {:error, :unreachable} ->
        {:ok, %{status: :unavailable, reachable: false}}
    end
  end

  def handle_action("route_query", params, opts) do
    FederationRouter.route_query(params, opts)
  end

  def handle_action(action, _params, _opts) do
    {:error, {:unknown_action, action}}
  end

  # Optional callbacks

  @impl true
  @spec supervisor_children() :: [Supervisor.child_spec()]
  def supervisor_children do
    [
      Apm.Plugins.Memory.MemoryClientBridge,
      Apm.Plugins.Memory.ObservationCache
    ]
  end

  @impl true
  @spec nav_items() :: [{String.t(), String.t(), String.t() | nil}]
  def nav_items do
    [{"Memory", "/memory", "hero-light-bulb"}]
  end

  @impl true
  @spec dashboard_widgets() :: [map()]
  def dashboard_widgets do
    [
      %{
        id: "memory_observations",
        name: "Memory Observations",
        category: :plugin,
        source_module: __MODULE__,
        refresh_interval: 60_000,
        min_width: 4,
        min_height: 3,
        config_schema: %{},
        plugin: "memory",
        version: @plugin_version,
        description: "Recent observations from claude-mem"
      }
    ]
  end

  @impl true
  @spec default_enabled?() :: boolean()
  def default_enabled?, do: true

  # Private helpers

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_datetime_opt(opts, _key, nil), do: opts

  defp maybe_put_datetime_opt(opts, key, iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} ->
        Keyword.put(opts, key, dt)

      {:error, reason} ->
        Logger.warning("[MemoryPlugin] Invalid datetime string for #{key}: #{inspect(reason)}")
        opts
    end
  end

  defp apply_list_opts(observations, opts) do
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 50)

    observations
    |> Enum.drop(offset)
    |> Enum.take(limit)
  end
end
