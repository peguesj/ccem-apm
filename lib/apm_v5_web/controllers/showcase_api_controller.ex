defmodule ApmV5Web.ShowcaseApiController do
  @moduledoc """
  Showcase data API endpoints.

  Extracted as part of refactor-max domain split to provide a dedicated
  REST surface for the GIMME-style project showcase.
  Reads project showcase data via ShowcaseDataStore and exposes it as JSON
  for external consumers or mobile clients.
  All routes mounted at /api/showcase/* in the router.
  """

  use ApmV5Web, :controller

  alias ApmV5.ShowcaseDataStore
  alias ApmV5.ConfigLoader

  @doc "GET /api/showcase -- list all showcase-eligible projects"
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    config = safe_get_config()
    all_projects = Map.get(config, "projects", [])
    showcase_projects = ShowcaseDataStore.filter_showcase_projects(all_projects)

    projects_list =
      showcase_projects
      |> Enum.map(fn p ->
        %{
          name: p["name"],
          source: p["source"] || "config",
          has_data: true
        }
      end)

    json(conn, %{
      projects: Enum.map(showcase_projects, fn p -> p["name"] end),
      details: projects_list,
      count: length(showcase_projects)
    })
  end

  @doc "GET /api/showcase/:project -- get showcase data for a specific project"
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"project" => project}) do
    data = ShowcaseDataStore.get_showcase_data(project)

    case data do
      %{} when map_size(data) == 0 ->
        conn
        |> put_status(404)
        |> json(%{error: "No showcase data found", project: project})

      data ->
        json(conn, Map.put(data, "project", project))
    end
  end

  @doc "POST /api/showcase/:project/reload -- reload showcase data for a project"
  @spec reload(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reload(conn, %{"project" => project}) do
    :ok = ShowcaseDataStore.reload(project)
    json(conn, %{ok: true, project: project})
  end

  # ============================
  # Private Helpers
  # ============================

  defp safe_get_config do
    try do
      ConfigLoader.get_config()
    catch
      :exit, _ -> %{"projects" => [], "active_project" => nil}
    end
  end
end
