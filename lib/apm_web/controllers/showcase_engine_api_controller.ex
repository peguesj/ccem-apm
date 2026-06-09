defmodule ApmWeb.ShowcaseEngineApiController do
  @moduledoc """
  REST surface for showcase engines.

  Routes (see router.ex):

      get  "/api/showcase/engines/:engine_id",        :fetch_json
      get  "/api/showcase/engines/:engine_id/health", :health
      post "/api/showcase/engines/:engine_id",        :ingest

  Project scoping (per `ApmWeb.Showcase.Engine.project_scope/0`):

    * `:any`    — no enforcement; the active project is informational.
    * `:strict` — `ingest/2` rejects payloads whose `project_name` field does
                  not match `Apm.ConfigLoader.get_active_project/0`. `fetch_json/2`
                  returns 404 when no active project is set.

  Failures return JSON `{"error": "<reason>"}` with appropriate HTTP status.
  """

  use ApmWeb, :controller

  alias ApmWeb.Showcase.Registry
  alias Apm.ConfigLoader

  # GET /api/showcase/engines/:engine_id/health
  def health(conn, %{"engine_id" => engine_id}) do
    case Registry.lookup(engine_id) do
      {:ok, _engine_mod} ->
        conn
        |> put_status(:ok)
        |> json(%{
          status: "ok",
          engine: engine_id,
          project: active_project_name()
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          status: "not_found",
          engine: engine_id,
          project: active_project_name(),
          error: "engine_not_registered"
        })
    end
  end

  # GET /api/showcase/engines/:engine_id
  def fetch_json(conn, %{"engine_id" => engine_id} = params) do
    with {:ok, engine_mod} <- Registry.lookup(engine_id),
         {:ok, active_project} <- require_project_for_engine(engine_mod),
         {:ok, payload} <- engine_mod.fetch(active_project, params) do
      conn
      |> put_status(:ok)
      |> json(%{engine: engine_id, project: active_project, payload: payload})
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", engine: engine_id})

      {:error, :project_unset} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "project_unset", engine: engine_id})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: inspect(reason), engine: engine_id})
    end
  end

  # POST /api/showcase/engines/:engine_id
  def ingest(conn, %{"engine_id" => engine_id} = params) do
    body =
      params
      |> Map.delete("engine_id")
      |> normalize_body()

    with {:ok, engine_mod} <- Registry.lookup(engine_id),
         true <- supports_post(engine_mod) || {:error, :ingest_unsupported},
         {:ok, active_project} <- require_project_for_engine(engine_mod),
         :ok <- enforce_project_scope(engine_mod, active_project, body),
         {:ok, stored} <- engine_mod.ingest(active_project, body) do
      conn
      |> put_status(:created)
      |> json(%{
        status: "ok",
        engine: engine_id,
        project: active_project,
        payload: stored
      })
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "engine_not_registered", engine: engine_id})

      {:error, :ingest_unsupported} ->
        conn
        |> put_status(:method_not_allowed)
        |> json(%{error: "ingest_unsupported", engine: engine_id})

      {:error, :project_unset} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "project_unset", engine: engine_id})

      {:error, :project_scope_mismatch} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "project_scope_mismatch", engine: engine_id})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason), engine: engine_id})
    end
  end

  # --- Internals ---

  defp supports_post(engine_mod) do
    if engine_mod.supports_post?(), do: true, else: false
  end

  defp require_project_for_engine(engine_mod) do
    case {engine_mod.project_scope(), active_project_name()} do
      {:strict, ""} -> {:error, :project_unset}
      {:strict, name} -> {:ok, name}
      {:any, name} -> {:ok, name}
    end
  end

  defp enforce_project_scope(engine_mod, active_project, body) do
    case engine_mod.project_scope() do
      :any ->
        :ok

      :strict ->
        case Map.get(body, "project_name") do
          ^active_project -> :ok
          _ -> {:error, :project_scope_mismatch}
        end
    end
  end

  defp active_project_name do
    case ConfigLoader.get_active_project() do
      %{"name" => name} when is_binary(name) -> name
      _ -> ""
    end
  rescue
    _ -> ""
  end

  # Phoenix puts JSON body keys directly into params (via Plug.Parsers + Jason).
  # For nested ingest payloads we just want the params minus the route capture.
  defp normalize_body(params) when is_map(params), do: params
  defp normalize_body(_), do: %{}
end
