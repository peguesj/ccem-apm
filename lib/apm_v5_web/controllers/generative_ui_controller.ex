defmodule ApmV5Web.V2.GenerativeUIController do
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

  use ApmV5Web, :controller

  alias ApmV5.AgUi.GenerativeUI.Registry

  def index(conn, params) do
    components =
      case params["agent_id"] do
        nil -> Registry.list_components()
        agent_id -> Registry.list_by_agent(agent_id)
      end

    json(conn, %{components: components})
  end

  def show(conn, %{"id" => id}) do
    case Registry.get(id) do
      nil -> conn |> put_status(404) |> json(%{error: "Component not found"})
      comp -> json(conn, comp)
    end
  end

  def create(conn, params) do
    agent_id = params["agent_id"] || "system"

    case Registry.register_component(agent_id, params) do
      {:ok, id} ->
        conn |> put_status(201) |> json(%{id: id, status: "registered"})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: reason})
    end
  end

  def update(conn, %{"id" => id} = params) do
    case Registry.update_component(id, Map.delete(params, "id")) do
      :ok -> json(conn, %{status: "updated"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Component not found"})
    end
  end

  def delete(conn, %{"id" => id}) do
    Registry.remove_component(id)
    json(conn, %{status: "removed"})
  end
end
