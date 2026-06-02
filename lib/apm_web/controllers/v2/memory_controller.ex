defmodule ApmWeb.V2.MemoryController do
  @moduledoc """
  REST API controller for the Memory plugin (US-418).

  Delegates all actions to `Apm.Plugins.Memory.MemoryPlugin.handle_action/3`.

  ## Endpoints

  - `GET /api/v2/memory/observations`       — list observations (query params: limit, offset)
  - `GET /api/v2/memory/observations/:id`   — get single observation by ID
  - `GET /api/v2/memory/search?query=...`   — semantic search across observations
  - `GET /api/v2/memory/timeline`           — timeline query (query params: from, to as ISO8601)
  - `GET /api/v2/memory/health`             — claude-mem worker health check
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmWeb.Plugs.OpenApiErrorRenderer

  alias Apm.Plugins.Memory.MemoryPlugin
  alias ApmWeb.Schemas

  # ── GET /api/v2/memory/observations ─────────────────────────────────────────

  @doc "List cached observations with optional limit/offset pagination."
  @spec list_observations(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :list_observations,
    summary: "List observations",
    tags: ["Memory"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def list_observations(conn, params) do
    action_params =
      %{}
      |> maybe_put_int("limit", params["limit"])
      |> maybe_put_int("offset", params["offset"])

    dispatch(conn, "list_observations", action_params)
  end

  # ── GET /api/v2/memory/observations/:id ─────────────────────────────────────

  @doc "Get a single observation by ID."
  @spec get_observation(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :get_observation,
    summary: "Get observation",
    tags: ["Memory"],
    responses: [
      ok: {"OK", "application/json", Schemas.Observation}
    ]

  def get_observation(conn, %{"id" => id} = _params) do
    dispatch(conn, "get_observation", %{"id" => id})
  end

  # ── GET /api/v2/memory/search?query=... ─────────────────────────────────────

  @doc "Semantic search across observations; falls back to ETS substring match."
  @spec search(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :search,
    summary: "Search",
    tags: ["Memory"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def search(conn, %{"query" => _} = params) do
    dispatch(conn, "search_observations", Map.take(params, ["query"]))
  end

  def search(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "query parameter is required"})
  end

  # ── GET /api/v2/memory/timeline?from=...&to=... ──────────────────────────────

  @doc "Observations in date range; from/to are optional ISO8601 datetime strings."
  @spec timeline(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :timeline,
    summary: "Timeline",
    tags: ["Memory"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def timeline(conn, params) do
    action_params = Map.take(params, ["from", "to"])
    dispatch(conn, "timeline", action_params)
  end

  # ── GET /api/v2/memory/health ────────────────────────────────────────────────

  @doc "Claude-mem worker reachability status."
  @spec health(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :health,
    summary: "Health check",
    tags: ["Memory"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def health(conn, _params) do
    dispatch(conn, "health_check", %{})
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp maybe_put_int(map, _key, nil), do: map

  defp maybe_put_int(map, key, val) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> Map.put(map, key, int)
      :error -> map
    end
  end

  defp maybe_put_int(map, key, val) when is_integer(val), do: Map.put(map, key, val)

  @spec dispatch(Plug.Conn.t(), String.t(), map()) :: Plug.Conn.t()
  defp dispatch(conn, action, params) do
    case MemoryPlugin.handle_action(action, params, []) do
      {:ok, data} ->
        json(conn, data)

      {:error, {:not_found, id}} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Observation not found", id: id})

      {:error, {:invalid_params, reason}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Internal error", detail: inspect(reason)})
    end
  end
end
