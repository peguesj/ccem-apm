defmodule ApmWeb.FormationApiController do
  @moduledoc """
  Formation management API endpoints.

  Extracted from ApiController as part of refactor-max domain split.
  Exposes formation CRUD and agent-listing under /api/formations/*.
  Delegates to Apm.UpmStore for formation data and Apm.AgentRegistry
  for formation-scoped agent queries.

  Broadcasts PubSub events on mutations to `"apm:formations"` topic.
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias ApmWeb.Schemas
  alias OpenApiSpex.Schema
  alias Apm.UpmStore
  alias Apm.AgentRegistry
  alias Apm.Upm.FormationStateMachine

  operation :list_formations,
    summary: "List formations",
    description: "Returns all formations from UpmStore.",
    tags: ["Formations"],
    responses: [
      ok: {"Formation list", "application/json", Schemas.OkResponse}
    ]

  operation :get_formation,
    summary: "Get formation",
    description: "Returns a single formation by ID with its agents.",
    tags: ["Formations"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Formation ID"]
    ],
    responses: [
      ok: {"Formation detail", "application/json", Schemas.OkResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]

  operation :create_formation,
    summary: "Create formation",
    description: "Creates a new formation from a template or raw params. Broadcasts via PubSub.",
    tags: ["Formations"],
    request_body: {"Formation payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      created: {"Formation created", "application/json", Schemas.OkResponse},
      unprocessable_entity: {"Unknown template", "application/json", Schemas.ErrorResponse}
    ]

  operation :update_formation,
    summary: "Update formation",
    description: "Updates a formation's attributes. Validates state transitions via FormationStateMachine.",
    tags: ["Formations"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Formation ID"]
    ],
    request_body: {"Formation update payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Formation updated", "application/json", Schemas.OkResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse},
      unprocessable_entity: {"Invalid state transition", "application/json", Schemas.ErrorResponse}
    ]

  operation :get_formation_agents,
    summary: "List formation agents",
    description: "Returns all agents belonging to a formation.",
    tags: ["Formations"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Formation ID"]
    ],
    responses: [
      ok: {"Formation agents", "application/json", Schemas.OkResponse}
    ]

  operation :dot,
    summary: "Formation DOT graph",
    description: "Returns a Graphviz DOT source string for the formation's agent graph.",
    tags: ["Formations"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Formation ID"]
    ],
    responses: [
      ok: {"DOT source (text/plain)", "text/plain", %Schema{type: :string}},
      not_found: {"Formation not found", "application/json", Schemas.ErrorResponse}
    ]

  # Catch-all for any action not explicitly annotated above.
  def open_api_operation(_action), do: nil

  @pubsub Apm.PubSub
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

    # If a status transition is requested, validate it via FormationStateMachine
    attrs_with_validated_status =
      case Map.get(attrs, "status") || Map.get(attrs, :status) do
        nil ->
          attrs

        requested_status ->
          with {:parse_new, {:ok, new_state}} <- {:parse_new, FormationStateMachine.parse(requested_status)},
               formation when not is_nil(formation) <- UpmStore.get_formation(id),
               current_raw = Map.get(formation, :status) || Map.get(formation, "status") || "registered",
               {:parse_current, {:ok, current_state}} <- {:parse_current, FormationStateMachine.parse(current_raw)},
               {:transition, {:ok, _}} <- {:transition, FormationStateMachine.transition(current_state, new_state)} do
            # Normalize status to string for backward compat storage
            Map.put(attrs, "status", Atom.to_string(new_state))
          else
            {:parse_new, _} ->
              # Unknown target state — pass through unchanged (API backward compat)
              attrs

            {:parse_current, _} ->
              # Current state unrecognized — allow update
              Map.put(attrs, "status", to_string(requested_status))

            {:transition, {:error, :invalid_transition}} ->
              # Encode invalid_transition sentinel — controller will return 422
              Map.put(attrs, "__fsm_error__", :invalid_transition)

            nil ->
              # Formation not found — let update_formation handle 404
              attrs
          end
      end

    case Map.get(attrs_with_validated_status, "__fsm_error__") do
      :invalid_transition ->
        conn
        |> put_status(422)
        |> json(%{error: "Invalid state transition", id: id})

      _ ->
        clean_attrs = Map.delete(attrs_with_validated_status, "__fsm_error__")

        case UpmStore.update_formation(id, clean_attrs) do
          :ok ->
            formation = UpmStore.get_formation(id)

            Phoenix.PubSub.broadcast(@pubsub, @topic, {:formation_updated, %{
              id: id,
              attrs: clean_attrs
            }})

            json(conn, formation)

          {:error, :not_found} ->
            conn
            |> put_status(404)
            |> json(%{error: "Formation not found", id: id})
        end
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
      dot_source = Apm.FormationDot.generate(id, agents)

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, dot_source)
    end
  end
end
