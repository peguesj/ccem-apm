defmodule ApmV5Web.FormationApiController do
  @moduledoc """
  Formation management API endpoints.

  Extracted from ApiController as part of refactor-max domain split.
  Exposes formation CRUD and agent-listing under /api/formations/*.
  Delegates to ApmV5.UpmStore for formation data and ApmV5.AgentRegistry
  for formation-scoped agent queries.

  Broadcasts PubSub events on mutations to `"apm:formations"` topic.
  """

  use ApmV5Web, :controller

  alias ApmV5.UpmStore
  alias ApmV5.AgentRegistry

  @pubsub ApmV5.PubSub
  @topic "apm:formations"

  @doc "GET /api/formations -- list all formations"
  @spec list_formations(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def list_formations(conn, _params) do
    formations = UpmStore.list_all_formations()
    json(conn, %{formations: formations, count: length(formations)})
  end

  @doc "GET /api/formations/:id -- get a single formation by ID"
  @spec get_formation(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def get_formation(conn, %{"id" => id}) do
    case UpmStore.get_formation(id) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{error: "Formation not found", id: id})

      formation ->
        agents = AgentRegistry.list_formation(id)
        json(conn, Map.put(formation, :agents, agents))
    end
  end

  @doc "POST /api/formations -- create a formation. Accepts optional `template` param for built-in templates."
  @spec create_formation(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_formation(conn, %{"template" => template_name} = params) do
    opts = if params["date"], do: %{date: params["date"]}, else: %{}

    case UpmStore.create_from_template(template_name, opts) do
      {:ok, id} ->
        formation = UpmStore.get_formation(id)

        Phoenix.PubSub.broadcast(@pubsub, @topic, {:formation_created, %{
          id: id,
          name: formation.name,
          template: template_name
        }})

        conn
        |> put_status(201)
        |> json(formation)

      {:error, :unknown_template} ->
        conn
        |> put_status(422)
        |> json(%{error: "Unknown template", template: template_name})
    end
  end

  def create_formation(conn, params) do
    {:ok, id} = UpmStore.register_formation(params)
    formation = UpmStore.get_formation(id)

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:formation_created, %{
      id: id,
      name: params["name"],
      formation_id: params["formation_id"]
    }})

    conn
    |> put_status(201)
    |> json(formation)
  end

  @doc "PATCH /api/formations/:id -- update a formation"
  @spec update_formation(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_formation(conn, %{"id" => id} = params) do
    attrs = Map.drop(params, ["id"])

    case UpmStore.update_formation(id, attrs) do
      :ok ->
        formation = UpmStore.get_formation(id)

        Phoenix.PubSub.broadcast(@pubsub, @topic, {:formation_updated, %{
          id: id,
          attrs: attrs
        }})

        json(conn, formation)

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Formation not found", id: id})
    end
  end

  @doc "GET /api/formations/:id/agents -- list agents in a formation"
  @spec get_formation_agents(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def get_formation_agents(conn, %{"id" => id}) do
    agents = AgentRegistry.list_formation(id)
    json(conn, %{agents: agents, count: length(agents), formation_id: id})
  end

  @doc "GET /api/formations/:id/dot -- Graphviz DOT source for a formation"
  @spec dot(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def dot(conn, %{"id" => id}) do
    agents =
      AgentRegistry.list_agents()
      |> Enum.filter(fn a -> (a[:formation_id] || a["formation_id"]) == id end)

    if agents == [] do
      conn
      |> put_status(404)
      |> json(%{error: "Formation not found", id: id})
    else
      dot_source = ApmV5.FormationDot.generate(id, agents)

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, dot_source)
    end
  end
end
