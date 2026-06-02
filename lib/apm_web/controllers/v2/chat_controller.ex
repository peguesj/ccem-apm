defmodule ApmWeb.V2.ChatController do
  @moduledoc """
  V2 REST controller for AG-UI chat message history.

  Provides GET /api/v2/chat/:scope for listing scoped messages and
  DELETE /api/v2/chat/:scope for clearing a chat scope.
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmWeb.Plugs.OpenApiErrorRenderer

  @doc "GET /api/v2/chat/:scope — list messages for a scope"
  operation :index,
    summary: "List",
    tags: ["Chat"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def index(conn, %{"scope" => scope} = params) do
    limit = params |> Map.get("limit", "50") |> String.to_integer() |> min(500)
    messages = Apm.ChatStore.list_messages(scope, limit)
    json(conn, %{data: messages, scope: scope, total: length(messages)})
  end

  @doc "POST /api/v2/chat/:scope/send — send a message to a scope"
  operation :send_message,
    summary: "Send message",
    tags: ["Chat"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def send_message(conn, %{"scope" => scope, "content" => content} = params) do
    metadata = Map.take(params, ["role", "agent_id"])

    case Apm.ChatStore.send_message(scope, content, metadata) do
      {:ok, message} ->
        conn |> put_status(:created) |> json(%{data: message})
    end
  end

  def send_message(conn, %{"scope" => _scope}) do
    conn |> put_status(:bad_request) |> json(%{error: "content is required"})
  end

  @doc "DELETE /api/v2/chat/:scope — clear messages for a scope"
  operation :clear,
    summary: "Clear",
    tags: ["Chat"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def clear(conn, %{"scope" => scope}) do
    Apm.ChatStore.clear_scope(scope)
    json(conn, %{ok: true, scope: scope})
  end
end
