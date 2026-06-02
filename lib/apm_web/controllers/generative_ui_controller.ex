defmodule ApmWeb.V2.GenerativeUIController do
  @moduledoc """
  REST API for GenerativeUI component management.

  ## US-023 Acceptance Criteria (DoD):
  - POST /api/v2/generative-ui/components registers a component
  - PUT /api/v2/generative-ui/components/:id updates
  - DELETE /api/v2/generative-ui/components/:id removes
  - GET /api/v2/generative-ui/components lists all, ?agent_id filters
  - Each mutation emits CUSTOM 'generative_ui_update' via EventBus
  - mix compile --warnings-as-errors passes
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmWeb.Plugs.OpenApiErrorRenderer

  alias Apm.AgUi.GenerativeUI.Registry

  operation :index,

    summary: "List",

    tags: ["Generative UI"],

    responses: [

      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}

    ]


  def index(conn, params) do
    components =
      case params["agent_id"] do
        nil -> Registry.list_components()
        agent_id -> Registry.list_by_agent(agent_id)
      end

    json(conn, %{components: components})
  end

  operation :show,

    summary: "Get one",

    tags: ["Generative UI"],

    responses: [

      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}

    ]


  def show(conn, %{"id" => id}) do
    case Registry.get(id) do
      nil -> conn |> put_status(404) |> json(%{error: "Component not found"})
      comp -> json(conn, comp)
    end
  end

  operation :create,

    summary: "Create",

    tags: ["Generative UI"],

    responses: [

      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}

    ]


  def create(conn, params) do
    agent_id = params["agent_id"] || "system"

    case Registry.register_component(agent_id, params) do
      {:ok, id} ->
        conn |> put_status(201) |> json(%{id: id, status: "registered"})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: reason})
    end
  end

  operation :update,

    summary: "Update",

    tags: ["Generative UI"],

    responses: [

      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}

    ]


  def update(conn, %{"id" => id} = params) do
    case Registry.update_component(id, Map.delete(params, "id")) do
      :ok -> json(conn, %{status: "updated"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Component not found"})
    end
  end

  operation :delete,

    summary: "Delete",

    tags: ["Generative UI"],

    responses: [

      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}

    ]


  def delete(conn, %{"id" => id}) do
    Registry.remove_component(id)
    json(conn, %{status: "removed"})
  end
end
