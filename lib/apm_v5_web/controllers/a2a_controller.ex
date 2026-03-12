defmodule ApmV5Web.V2.A2AController do
  @moduledoc """
  REST API + SSE streaming for A2A messaging.

  ## US-032 Acceptance Criteria (DoD):
  - POST /api/v2/a2a/send — send an A2A envelope
  - GET /api/v2/a2a/messages/:agent_id — get queued messages
  - POST /api/v2/a2a/ack — acknowledge a message
  - GET /api/v2/a2a/stats — router statistics
  - GET /api/v2/a2a/history/:agent_id — message history

  ## US-033 Acceptance Criteria (DoD):
  - GET /api/v2/a2a/stream/:agent_id — SSE stream of incoming A2A messages
  - 15s keepalive heartbeat
  - Subscribes to EventBus 'a2a:{agent_id}' topic
  - mix compile --warnings-as-errors passes
  """

  use ApmV5Web, :controller

  alias ApmV5.AgUi.A2A.{Router, Patterns}
  alias ApmV5.AgUi.EventBus

  # -- REST Endpoints (US-032) ------------------------------------------------

  @doc "POST /api/v2/a2a/send — send an A2A message"
  def send_message(conn, params) do
    case Router.send(params) do
      {:ok, message_id} ->
        json(conn, %{ok: true, message_id: message_id})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{ok: false, error: to_string(reason)})
    end
  end

  @doc "GET /api/v2/a2a/messages/:agent_id — get queued messages"
  def messages(conn, %{"agent_id" => agent_id}) do
    messages = Router.get_messages(agent_id)
    json(conn, %{agent_id: agent_id, messages: messages, count: length(messages)})
  end

  @doc "POST /api/v2/a2a/ack — acknowledge a message"
  def ack(conn, %{"agent_id" => agent_id, "message_id" => message_id}) do
    Router.ack_message(agent_id, message_id)
    json(conn, %{ok: true})
  end

  def ack(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{ok: false, error: "agent_id and message_id required"})
  end

  @doc "GET /api/v2/a2a/stats — router statistics"
  def stats(conn, _params) do
    json(conn, Router.stats())
  end

  @doc "GET /api/v2/a2a/history/:agent_id — message history"
  def history(conn, %{"agent_id" => agent_id}) do
    json(conn, %{agent_id: agent_id, history: Router.history(agent_id)})
  end

  @doc "POST /api/v2/a2a/broadcast — broadcast to all agents"
  def broadcast_message(conn, params) do
    from = params["from_agent_id"]

    case Patterns.broadcast(params, from) do
      {:ok, message_id} ->
        json(conn, %{ok: true, message_id: message_id})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{ok: false, error: to_string(reason)})
    end
  end

  @doc "POST /api/v2/a2a/fan-out — fan out to specific agents"
  def fan_out(conn, params) do
    from = params["from_agent_id"]
    targets = params["targets"] || []

    {:ok, result} = Patterns.fan_out(params, from, targets)
    json(conn, %{ok: true, sent: result.sent, results: result.results})
  end

  # -- SSE Streaming (US-033) -------------------------------------------------

  @doc "GET /api/v2/a2a/stream/:agent_id — SSE stream of A2A messages"
  def stream(conn, %{"agent_id" => agent_id}) do
    topic = "a2a:#{agent_id}"
    EventBus.subscribe(topic)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    # Send initial connected event
    {:ok, conn} = chunk(conn, "event: connected\ndata: {\"agent_id\":\"#{agent_id}\"}\n\n")

    stream_loop(conn, topic)
  end

  defp stream_loop(conn, topic) do
    receive do
      {:event_bus, ^topic, event} ->
        data = Jason.encode!(event)
        case chunk(conn, "event: a2a_message\ndata: #{data}\n\n") do
          {:ok, conn} -> stream_loop(conn, topic)
          {:error, _} -> EventBus.unsubscribe()
        end
    after
      15_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> stream_loop(conn, topic)
          {:error, _} -> EventBus.unsubscribe()
        end
    end
  end
end
