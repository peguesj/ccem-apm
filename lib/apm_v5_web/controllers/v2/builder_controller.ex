defmodule ApmV5Web.V2.BuilderController do
  @moduledoc """
  REST API for the Builder plugin wizard (v2).

  Routes (all under /api/v2/builder):
    POST  /sessions                — start a new wizard session
    GET   /sessions/:id            — get session state
    PATCH /sessions/:id            — update session fields
    POST  /sessions/:id/analyze    — trigger async source analysis
    POST  /sessions/:id/generate   — trigger async preview generation
    POST  /sessions/:id/write      — write generated files to disk
  """

  use ApmV5Web, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmV5Web.Plugs.OpenApiErrorRenderer

  alias ApmV5.Plugins.Builder.BuilderEngine

  operation :start_session,

    summary: "Start session",

    tags: ["Builder"],

    responses: [

      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}

    ]


  def start_session(conn, _params) do
    case BuilderEngine.start_session() do
      {:ok, id} -> json(conn |> put_status(:created), %{id: id})
      {:error, reason} -> json(conn |> put_status(:internal_server_error), %{error: inspect(reason)})
    end
  end

  operation :get_session,

    summary: "Get session",

    tags: ["Builder"],

    responses: [

      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}

    ]


  def get_session(conn, %{"id" => id}) do
    case BuilderEngine.get_session(id) do
      {:ok, session} -> json(conn, session_to_map(session))
      {:error, :not_found} -> json(conn |> put_status(:not_found), %{error: "session not found"})
    end
  end

  operation :update_session,

    summary: "Update session",

    tags: ["Builder"],

    responses: [

      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}

    ]


  def update_session(conn, %{"id" => id} = params) do
    attrs = Map.drop(params, ["id"])

    case BuilderEngine.update_session(id, attrs) do
      {:ok, session} -> json(conn, session_to_map(session))
      {:error, :not_found} -> json(conn |> put_status(:not_found), %{error: "session not found"})
    end
  end

  operation :analyze_source,

    summary: "Analyze source",

    tags: ["Builder"],

    responses: [

      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}

    ]


  def analyze_source(conn, %{"id" => id}) do
    case BuilderEngine.analyze_source(id) do
      :ok -> json(conn, %{status: "analyzing"})
      {:error, :not_found} -> json(conn |> put_status(:not_found), %{error: "session not found"})
    end
  end

  operation :generate_preview,

    summary: "Generate preview",

    tags: ["Builder"],

    responses: [

      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}

    ]


  def generate_preview(conn, %{"id" => id}) do
    case BuilderEngine.generate_preview(id) do
      :ok -> json(conn, %{status: "generating"})
      {:error, :not_found} -> json(conn |> put_status(:not_found), %{error: "session not found"})
    end
  end

  operation :write_files,

    summary: "Write files",

    tags: ["Builder"],

    responses: [

      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}

    ]


  def write_files(conn, %{"id" => id}) do
    case BuilderEngine.write_files(id) do
      {:ok, paths} -> json(conn, %{status: "complete", paths: paths})
      {:error, :not_found} -> json(conn |> put_status(:not_found), %{error: "session not found"})
      {:error, reason} -> json(conn |> put_status(:internal_server_error), %{error: inspect(reason)})
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp session_to_map(session) do
    %{
      id: session.id,
      name: session.name,
      description: session.description,
      source: session.source,
      capabilities: session.capabilities,
      analyzed: session.analyzed,
      generated_plugin_code: session.generated_plugin_code,
      generated_skill_md: session.generated_skill_md,
      status: session.status,
      error: session.error,
      created_at: session.created_at
    }
  end
end
