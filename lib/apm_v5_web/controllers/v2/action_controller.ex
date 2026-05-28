defmodule ApmV5Web.V2.ActionController do
  @moduledoc """
  REST API for ActionEngine catalog and async run management.

  ## Routes (all under /api/v2)

  - `GET  /actions`           — list ActionEngine @catalog
  - `POST /actions/:type`     — start async run, return 202 + run_id
  - `GET  /actions/runs`      — list recent runs (query: action_type, limit)
  - `GET  /actions/runs/:id`  — fetch single run by id
  """

  use ApmV5Web, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmV5Web.Plugs.OpenApiErrorRenderer

  alias ApmV5.ActionEngine
  alias ApmV5.ActionRunStore

  # ── GET /api/v2/actions ───────────────────────────────────────────────────

  @doc "Returns the ActionEngine catalog as a JSON list."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :index,
    summary: "List",
    tags: ["Actions"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def index(conn, _params) do
    catalog =
      ActionEngine.list_catalog()
      |> Enum.map(fn entry ->
        %{
          id: entry.id,
          name: entry.name,
          category: entry.category,
          icon: entry.icon,
          description: entry.description
        }
      end)

    json(conn, %{data: catalog})
  end

  # ── POST /api/v2/actions/:type ────────────────────────────────────────────

  @doc "Starts an async action run. Returns 202 on success, 404 for unknown type."
  @spec run(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :run,
    summary: "Run",
    tags: ["Actions"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def run(conn, %{"type" => action_type} = params) do
    project_path = Map.get(params, "project_path", System.tmp_dir!())
    action_params = Map.get(params, "params", %{})

    case ActionRunStore.start_run(action_type, project_path, action_params) do
      {:ok, run_id} ->
        conn
        |> put_status(:accepted)
        |> json(%{
          run_id: run_id,
          status: "pending",
          started_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })

      {:error, :unknown_action} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "unknown_action", message: "Action type '#{action_type}' not found in catalog"}})
    end
  end

  # ── GET /api/v2/actions/runs ──────────────────────────────────────────────

  @doc "Lists recent runs. Query params: action_type (optional), limit (default 50)."
  @spec list_runs(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :list_runs,
    summary: "List runs",
    tags: ["Actions"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def list_runs(conn, params) do
    opts =
      []
      |> maybe_add_action_type(params)
      |> maybe_add_limit(params)

    runs = ActionRunStore.list_runs(opts)
    json(conn, %{data: runs})
  end

  # ── GET /api/v2/actions/runs/:run_id ──────────────────────────────────────

  @doc "Fetches a single run by id."
  @spec get_run(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation :get_run,
    summary: "Get run",
    tags: ["Actions"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def get_run(conn, %{"run_id" => run_id}) do
    case ActionRunStore.get_run(run_id) do
      {:ok, run} ->
        json(conn, %{data: run})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "Run '#{run_id}' not found"}})
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  @spec maybe_add_action_type(keyword(), map()) :: keyword()
  defp maybe_add_action_type(opts, %{"action_type" => at}) when is_binary(at) and at != "",
    do: Keyword.put(opts, :action_type, at)

  defp maybe_add_action_type(opts, _), do: opts

  @spec maybe_add_limit(keyword(), map()) :: keyword()
  defp maybe_add_limit(opts, %{"limit" => lim}) do
    case Integer.parse(to_string(lim)) do
      {n, _} when n > 0 -> Keyword.put(opts, :limit, n)
      _ -> opts
    end
  end

  defp maybe_add_limit(opts, _), do: opts
end
