defmodule ApmV5Web.V2.RepositoryController do
  @moduledoc """
  REST API controller for plugin repository (marketplace) management.

  Routes under /api/v2/plugins/repositories:
    GET    /api/v2/plugins/repositories        — list all repositories
    POST   /api/v2/plugins/repositories        — add a custom repository
    GET    /api/v2/plugins/repositories/:name   — get repo by name
    PATCH  /api/v2/plugins/repositories/:name   — update repo metadata
    DELETE /api/v2/plugins/repositories/:name   — delete (custom only)
  """

  use ApmV5Web, :controller

  alias ApmV5.Plugins.PluginRepositoryStore

  @doc "GET /api/v2/plugins/repositories — list all repositories"
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    repos = PluginRepositoryStore.list_repos()
    json(conn, %{data: repos, count: length(repos)})
  end

  @doc "POST /api/v2/plugins/repositories — add a custom repository"
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    case PluginRepositoryStore.add_repo(params) do
      {:ok, repo} -> conn |> put_status(201) |> json(%{data: repo})
      {:error, reason} -> conn |> put_status(400) |> json(%{error: to_string(reason)})
    end
  end

  @doc "GET /api/v2/plugins/repositories/:name — get a single repository by name"
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"name" => name}) do
    case PluginRepositoryStore.get_repo(name) do
      {:ok, repo} -> json(conn, %{data: repo})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  @doc "PATCH /api/v2/plugins/repositories/:name — update repo metadata"
  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"name" => name} = params) do
    case PluginRepositoryStore.update_repo(name, Map.delete(params, "name")) do
      {:ok, repo} -> json(conn, %{data: repo})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  @doc "DELETE /api/v2/plugins/repositories/:name — delete (custom repos only)"
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"name" => name}) do
    case PluginRepositoryStore.delete_repo(name) do
      :ok -> send_resp(conn, 204, "")
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
      {:error, :builtin_protected} -> conn |> put_status(403) |> json(%{error: "Cannot delete built-in repository"})
    end
  end
end
