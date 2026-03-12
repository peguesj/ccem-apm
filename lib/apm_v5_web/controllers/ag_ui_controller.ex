defmodule ApmV5Web.AgUiController do
  @moduledoc """
  AG-UI Server-Sent Events endpoint.

  GET /api/ag-ui/events streams AG-UI protocol events via SSE.
  Supports optional `agent_id` query parameter to filter events.
  """

  use ApmV5Web, :controller

  alias ApmV5.EventStream

  @doc """
  SSE endpoint that streams AG-UI events.

  Subscribes to the EventStream PubSub topic and forwards events
  as SSE `data:` lines. The connection stays open until the client
  disconnects.

  Query params:
    - agent_id: optional, filter events to a specific agent
  """
  def events(conn, params) do
    agent_id = params["agent_id"]

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    # Subscribe to AG-UI events
    EventStream.subscribe()

    # Send initial STATE_SNAPSHOT so the client has current state
    agents = ApmV5.AgentRegistry.list_agents()
    sessions = ApmV5.AgentRegistry.list_sessions()
    notifications = ApmV5.AgentRegistry.get_notifications()

    snapshot_event =
      EventStream.emit_state_snapshot(%{
        agents: agents,
        sessions: sessions,
        notifications: notifications
      })

    # Send the initial snapshot as SSE
    case send_sse_event(conn, snapshot_event) do
      {:ok, conn} ->
        # Enter the event loop
        sse_loop(conn, agent_id)

      {:error, _reason} ->
        conn
    end
  end

  defp sse_loop(conn, agent_id) do
    receive do
      {:ag_ui_event, event} ->
        if should_send?(event, agent_id) do
          case send_sse_event(conn, event) do
            {:ok, conn} ->
              sse_loop(conn, agent_id)

            {:error, _reason} ->
              # Client disconnected
              conn
          end
        else
          sse_loop(conn, agent_id)
        end
    after
      # Send keepalive comment every 30 seconds to prevent timeout
      30_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} ->
            sse_loop(conn, agent_id)

          {:error, _reason} ->
            conn
        end
    end
  end

  defp should_send?(_event, nil), do: true

  defp should_send?(event, agent_id) do
    event_agent = get_in(event, [:data, :agent_id])
    # Send if event has no agent_id (global events like STATE_SNAPSHOT) or matches filter
    is_nil(event_agent) or event_agent == agent_id
  end

  defp send_sse_event(conn, event) do
    json_data = Jason.encode!(event)

    sse_payload =
      "id: #{event.sequence}\nevent: #{event.type}\ndata: #{json_data}\n\n"

    chunk(conn, sse_payload)
  end
end
