defmodule ApmWeb.ShowcaseApiController do
  @moduledoc """
  Showcase data API endpoints.

  Extracted as part of refactor-max domain split to provide a dedicated
  REST surface for the GIMME-style project showcase.
  Reads project showcase data via ShowcaseDataStore and exposes it as JSON
  for external consumers or mobile clients.
  All routes mounted at /api/showcase/* in the router.

  Broadcasts PubSub events on mutations to `"apm:showcase"` topic.
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias ApmWeb.Schemas
  alias Apm.ShowcaseDataStore
  alias Apm.ConfigLoader

  operation :index,
    summary: "List showcase projects",
    description: "Returns all showcase-eligible projects from the APM config.",
    tags: ["CCEM Management"],
    responses: [
      ok: {"Showcase project list", "application/json", Schemas.OkResponse}
    ]

  operation :show,
    summary: "Get showcase data",
    description: "Returns showcase data for a specific project.",
    tags: ["CCEM Management"],
    parameters: [
      project: [in: :path, type: :string, required: true, description: "Project name"]
    ],
    responses: [
      ok: {"Showcase project data", "application/json", Schemas.OkResponse},
      not_found: {"No data found", "application/json", Schemas.ErrorResponse}
    ]

  operation :reload,
    summary: "Reload showcase data",
    description: "Reloads showcase data for a project from disk and broadcasts via PubSub.",
    tags: ["CCEM Management"],
    parameters: [
      project: [in: :path, type: :string, required: true, description: "Project name"]
    ],
    responses: [
      ok: {"Reload result", "application/json", Schemas.OkResponse}
    ]

  operation :diagrams,
    summary: "List diagrams",
    description: "Returns diagram metadata (without content) for a showcase project.",
    tags: ["CCEM Management"],
    parameters: [
      project: [in: :path, type: :string, required: true, description: "Project name"]
    ],
    responses: [
      ok: {"Diagram list", "application/json", Schemas.OkResponse}
    ]

  operation :diagram,
    summary: "Get diagram",
    description: "Returns a single diagram with full content for a showcase project.",
    tags: ["CCEM Management"],
    parameters: [
      project: [in: :path, type: :string, required: true, description: "Project name"],
      id: [in: :path, type: :string, required: true, description: "Diagram ID"]
    ],
    responses: [
      ok: {"Diagram detail", "application/json", Schemas.OkResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]

  operation :tabs,
    summary: "List showcase tabs",
    description: "Returns tab metadata (without data) for a showcase project.",
    tags: ["CCEM Management"],
    parameters: [
      project: [in: :path, type: :string, required: true, description: "Project name"]
    ],
    responses: [
      ok: {"Tab list", "application/json", Schemas.OkResponse}
    ]

  operation :tab_data,
    summary: "Get tab data",
    description: "Returns data for a specific tab in a showcase project, with optional search/filter/sort.",
    tags: ["CCEM Management"],
    parameters: [
      project: [in: :path, type: :string, required: true, description: "Project name"],
      tab_id: [in: :path, type: :string, required: true, description: "Tab ID"],
      search: [in: :query, type: :string, required: false, description: "Search query"],
      filter: [in: :query, type: :string, required: false, description: "Filter expression"],
      sort: [in: :query, type: :string, required: false, description: "Sort field"]
    ],
    responses: [
      ok: {"Tab data", "application/json", Schemas.OkResponse}
    ]

  # Catch-all for any action not explicitly annotated above.
  def open_api_operation(_action), do: nil

  @pubsub Apm.PubSub
  @topic "apm:showcase"

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

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:showcase_reloaded, %{project: project}})

    json(conn, %{ok: true, project: project})
  end

  @doc "GET /api/showcase/:project/diagrams -- list diagrams for a project"
  @spec diagrams(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def diagrams(conn, %{"project" => project}) do
    diagrams = ShowcaseDataStore.get_diagrams(project)

    diagram_list =
      Enum.map(diagrams, fn d -> Map.drop(d, ["content"]) end)

    json(conn, %{project: project, diagrams: diagram_list, count: length(diagram_list)})
  end

  @doc "GET /api/showcase/:project/diagrams/:id -- get single diagram with content"
  @spec diagram(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def diagram(conn, %{"project" => project, "id" => id}) do
    diagrams = ShowcaseDataStore.get_diagrams(project)

    case Enum.find(diagrams, fn d -> d["id"] == id end) do
      nil ->
        conn |> put_status(404) |> json(%{error: "diagram_not_found", id: id})

      found ->
        json(conn, Map.put(found, "project", project))
    end
  end

  @doc "GET /api/showcase/:project/tabs -- list queryable tabs for a project"
  @spec tabs(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def tabs(conn, %{"project" => project}) do
    tabs = ShowcaseDataStore.get_tabs(project)
    tab_list = Enum.map(tabs, fn t -> Map.drop(t, ["data"]) end)
    json(conn, %{project: project, tabs: tab_list, count: length(tab_list)})
  end

  @doc "GET /api/showcase/:project/tabs/:tab_id -- get tab data with optional query"
  @spec tab_data(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def tab_data(conn, %{"project" => project, "tab_id" => tab_id} = params) do
    query = Map.take(params, ["search", "filter", "sort"])
    data = ShowcaseDataStore.get_tab_data(project, tab_id, query)
    json(conn, %{project: project, tab_id: tab_id, data: data})
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
