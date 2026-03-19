defmodule ApmV5Web.FormationApiController do
  @moduledoc """
  Formation management API endpoints.

  Extracted from ApiController as part of refactor-max domain split.
  Exposes formation CRUD and agent-listing under /api/formations/*.
  Delegates to ApmV5.UpmStore for formation data and ApmV5.AgentRegistry
  for formation-scoped agent queries.
  """

  use ApmV5Web, :controller

  alias ApmV5.UpmStore
  alias ApmV5.AgentRegistry

  @doc "GET /api/formations -- list all formations"
  @spec list_formations(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def list_formations(conn, _params) do
    formations = UpmStore.list_formations()
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

  @doc "POST /api/formations -- create a formation"
  @spec create_formation(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_formation(conn, params) do
    {:ok, id} = UpmStore.register_formation(params)
    formation = UpmStore.get_formation(id)

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
end
