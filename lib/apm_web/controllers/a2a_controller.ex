defmodule ApmWeb.V2.A2AController do
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

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmWeb.Plugs.OpenApiErrorRenderer

  alias Apm.AgUi.A2A.{Router, Patterns, TopicRegistry}
  alias Apm.AgUi.EventBus

  # -- REST Endpoints (US-032) ------------------------------------------------

  @doc "POST /api/v2/a2a/send — send an A2A message"
  operation(:send_message,
    summary: "Send message",
    tags: ["A2A"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

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
  operation(:messages,
    summary: "List messages",
    tags: ["A2A"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def messages(conn, %{"agent_id" => agent_id}) do
    messages = Router.get_messages(agent_id)
    json(conn, %{agent_id: agent_id, messages: messages, count: length(messages)})
  end

  @doc "POST /api/v2/a2a/ack — acknowledge a message"
  operation(:ack,
    summary: "Acknowledge",
    tags: ["A2A"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

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
  operation(:stats,
    summary: "Statistics",
    tags: ["A2A"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def stats(conn, _params) do
    json(conn, Router.stats())
  end

  @doc "GET /api/v2/a2a/history/:agent_id — message history"
  operation(:history,
    summary: "History",
    tags: ["A2A"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def history(conn, %{"agent_id" => agent_id}) do
    json(conn, %{agent_id: agent_id, history: Router.history(agent_id)})
  end

  @doc "POST /api/v2/a2a/broadcast — broadcast to all agents"
  operation(:broadcast_message,
    summary: "Broadcast message",
    tags: ["A2A"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

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
  operation(:fan_out,
    summary: "Fan-out message",
    tags: ["A2A"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def fan_out(conn, params) do
    from = params["from_agent_id"]
    targets = params["targets"] || []

    {:ok, result} = Patterns.fan_out(params, from, targets)
    json(conn, %{ok: true, sent: result.sent, results: result.results})
  end

  # -- Topic Subscription (coord-a2 hotfix, v9.2.1) ---------------------------

  @doc "POST /api/v2/a2a/topics/subscribe — subscribe an agent to a topic"
  operation(:subscribe_topic,
    summary: "Subscribe to topic",
    tags: ["A2A"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def subscribe_topic(conn, %{"agent_id" => agent_id, "topic" => topic})
      when is_binary(agent_id) and is_binary(topic) do
    :ok = TopicRegistry.subscribe(agent_id, topic)
    json(conn, %{ok: true, agent_id: agent_id, topic: topic})
  end

  def subscribe_topic(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{ok: false, error: "agent_id and topic required"})
  end

  @doc "DELETE /api/v2/a2a/topics/subscribe — unsubscribe agent from topic(s)"
  operation(:unsubscribe_topic,
    summary: "Unsubscribe from topic",
    tags: ["A2A"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def unsubscribe_topic(conn, %{"agent_id" => agent_id, "topic" => topic})
      when is_binary(agent_id) and is_binary(topic) do
    :ok = TopicRegistry.unsubscribe(agent_id, topic)
    json(conn, %{ok: true, agent_id: agent_id, topic: topic})
  end

  def unsubscribe_topic(conn, %{"agent_id" => agent_id}) when is_binary(agent_id) do
    :ok = TopicRegistry.unsubscribe_all(agent_id)
    json(conn, %{ok: true, agent_id: agent_id, unsubscribed: :all})
  end

  def unsubscribe_topic(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{ok: false, error: "agent_id required"})
  end

  @doc "GET /api/v2/a2a/topics — list all topics with subscriber counts"
  operation(:list_topics,
    summary: "List topics",
    tags: ["A2A"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def list_topics(conn, _params) do
    json(conn, %{topics: TopicRegistry.list_topics()})
  end

  @doc "GET /api/v2/a2a/topics/:topic/subscribers — list agents subscribed to topic"
  operation(:topic_subscribers,
    summary: "List topic subscribers",
    tags: ["A2A"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def topic_subscribers(conn, %{"topic" => topic}) do
    subscribers = TopicRegistry.get_subscribers(topic)
    json(conn, %{topic: topic, subscribers: subscribers, count: length(subscribers)})
  end

  # -- SSE Streaming (US-033) -------------------------------------------------

  @doc "GET /api/v2/a2a/stream/:agent_id — SSE stream of A2A messages"
  operation(:stream,
    summary: "Stream",
    tags: ["A2A"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

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
