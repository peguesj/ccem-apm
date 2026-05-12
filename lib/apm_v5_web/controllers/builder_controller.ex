defmodule ApmV5Web.BuilderController do
  @moduledoc """
  REST API for the Builder plugin wizard.

  Routes (all under /api/v2/builder):
    POST  /sessions                  — start a new wizard session
    GET   /sessions/:id              — get session state
    PATCH /sessions/:id              — update session fields
    POST  /sessions/:id/analyze      — trigger async source analysis
    POST  /sessions/:id/generate     — trigger async preview generation
    POST  /sessions/:id/write        — write generated files to disk
  """

  use ApmV5Web, :controller

  alias ApmV5.Plugins.Builder.BuilderEngine

  def start_session(conn, _params) do
    case BuilderEngine.start_session() do
      {:ok, id} -> json(conn |> put_status(:created), %{id: id})
      {:error, reason} -> json(conn |> put_status(:internal_server_error), %{error: inspect(reason)})
    end
  end

  def get_session(conn, %{"id" => id}) do
    case BuilderEngine.get_session(id) do
      {:ok, session} -> json(conn, session_to_map(session))
      {:error, :not_found} -> json(conn |> put_status(:not_found), %{error: "session not found"})
    end
  end

  def update_session(conn, %{"id" => id} = params) do
    attrs = Map.drop(params, ["id"])

    case BuilderEngine.update_session(id, attrs) do
      {:ok, session} -> json(conn, session_to_map(session))
      {:error, :not_found} -> json(conn |> put_status(:not_found), %{error: "session not found"})
    end
  end

  def analyze_source(conn, %{"id" => id}) do
    case BuilderEngine.analyze_source(id) do
      :ok -> json(conn, %{status: "analyzing"})
      {:error, :not_found} -> json(conn |> put_status(:not_found), %{error: "session not found"})
    end
  end

  def generate_preview(conn, %{"id" => id}) do
    case BuilderEngine.generate_preview(id) do
      :ok -> json(conn, %{status: "generating"})
      {:error, :not_found} -> json(conn |> put_status(:not_found), %{error: "session not found"})
    end
  end

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
