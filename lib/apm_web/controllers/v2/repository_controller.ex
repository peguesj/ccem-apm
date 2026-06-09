defmodule ApmWeb.V2.RepositoryController do
  @moduledoc """
  REST API controller for plugin repository (marketplace) management.

  Routes under /api/v2/plugins/repositories:
    GET    /api/v2/plugins/repositories        — list all repositories
    POST   /api/v2/plugins/repositories        — add a custom repository
    GET    /api/v2/plugins/repositories/:name   — get repo by name
    PATCH  /api/v2/plugins/repositories/:name   — update repo metadata
    DELETE /api/v2/plugins/repositories/:name   — delete (custom only)
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmWeb.Plugs.OpenApiErrorRenderer

  alias Apm.Plugins.PluginRepositoryStore

  @doc "GET /api/v2/plugins/repositories — list all repositories"
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation(:index,
    summary: "List",
    tags: ["Plugins"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def index(conn, _params) do
    repos = PluginRepositoryStore.list_repos()
    json(conn, %{data: repos, count: length(repos)})
  end

  @doc "POST /api/v2/plugins/repositories — add a custom repository"
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation(:create,
    summary: "Create",
    tags: ["Plugins"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def create(conn, params) do
    case PluginRepositoryStore.add_repo(params) do
      {:ok, repo} -> conn |> put_status(201) |> json(%{data: repo})
      {:error, reason} -> conn |> put_status(400) |> json(%{error: to_string(reason)})
    end
  end

  @doc "GET /api/v2/plugins/repositories/:name — get a single repository by name"
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation(:show,
    summary: "Get one",
    tags: ["Plugins"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def show(conn, %{"name" => name}) do
    case PluginRepositoryStore.get_repo(name) do
      {:ok, repo} -> json(conn, %{data: repo})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  @doc "PATCH /api/v2/plugins/repositories/:name — update repo metadata"
  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation(:update,
    summary: "Update",
    tags: ["Plugins"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def update(conn, %{"name" => name} = params) do
    case PluginRepositoryStore.update_repo(name, Map.delete(params, "name")) do
      {:ok, repo} -> json(conn, %{data: repo})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  @doc "DELETE /api/v2/plugins/repositories/:name — delete (custom repos only)"
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation(:delete,
    summary: "Delete",
    tags: ["Plugins"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def delete(conn, %{"name" => name}) do
    case PluginRepositoryStore.delete_repo(name) do
      :ok ->
        send_resp(conn, 204, "")

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not found"})

      {:error, :builtin_protected} ->
        conn |> put_status(403) |> json(%{error: "Cannot delete built-in repository"})
    end
  end
end
