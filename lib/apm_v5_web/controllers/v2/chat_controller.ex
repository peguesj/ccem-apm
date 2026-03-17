defmodule ApmV5Web.V2.ChatController do
  @moduledoc """
  V2 REST controller for AG-UI chat message history.

  Provides GET /api/v2/chat/:scope for listing scoped messages and
  DELETE /api/v2/chat/:scope for clearing a chat scope.
  """

  use ApmV5Web, :controller

  @doc "GET /api/v2/chat/:scope — list messages for a scope"
  def index(conn, %{"scope" => scope} = params) do
    limit = params |> Map.get("limit", "50") |> String.to_integer() |> min(500)
    messages = ApmV5.ChatStore.list_messages(scope, limit)
    json(conn, %{data: messages, scope: scope, total: length(messages)})
  end

  @doc "POST /api/v2/chat/:scope/send — send a message to a scope"
  def send_message(conn, %{"scope" => scope, "content" => content} = params) do
    metadata = Map.take(params, ["role", "agent_id"])

    case ApmV5.ChatStore.send_message(scope, content, metadata) do
      {:ok, message} ->
        conn |> put_status(:created) |> json(%{data: message})
    end
  end

  def send_message(conn, %{"scope" => _scope}) do
    conn |> put_status(:bad_request) |> json(%{error: "content is required"})
  end

  @doc "DELETE /api/v2/chat/:scope — clear messages for a scope"
  def clear(conn, %{"scope" => scope}) do
    ApmV5.ChatStore.clear_scope(scope)
    json(conn, %{ok: true, scope: scope})
  end
end
