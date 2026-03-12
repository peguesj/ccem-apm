defmodule ApmV5Web.V2.AgUiV2Controller do
  @moduledoc """
  AG-UI Protocol v2 API controller.

  Provides endpoints for emitting events, streaming via SSE,
  and managing per-agent state with snapshot/delta pattern.
  """

  use ApmV5Web, :controller

  alias ApmV5.AgUi.{EventRouter, StateManager, HookBridge}
  alias ApmV5.EventStream
  alias AgUi.Core.Events.EventType

  @doc """
  POST /api/v2/ag-ui/emit

  Emits an AG-UI event. Accepts:
  - `type` (required): AG-UI event type string
  - `data` (required): Event payload map
  - `legacy_bridge` (optional): If true, translates as legacy hook payload
  """
  def emit(conn, %{"type" => type, "data" => data}) do
    if EventType.valid?(type) do
      event = EventRouter.emit_and_route(type, atomize_keys(data))
      json(conn, %{ok: true, event: event})
    else
      conn
      |> put_status(422)
      |> json(%{error: "Invalid AG-UI event type: #{type}", valid_types: EventType.all()})
    end
  end

  def emit(conn, %{"legacy_bridge" => bridge_type} = params) do
    event =
      case bridge_type do
        "register" -> HookBridge.translate_register(params)
        "heartbeat" -> HookBridge.translate_heartbeat(params)
        "notify" -> HookBridge.translate_notification(params)
        "tool_use" -> HookBridge.translate_tool_use(params)
        _ -> %{error: "unknown bridge type: #{bridge_type}"}
      end

    json(conn, %{ok: true, event: event})
  end

  def emit(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "Missing required fields: type, data"})
  end

  @doc """
  GET /api/v2/ag-ui/events

  SSE endpoint streaming all AG-UI events.
  Query params:
  - `since`: sequence number to replay from (optional)
  - `types`: comma-separated event type filter (optional)
  """
  def stream_events(conn, params) do
    types_filter = parse_types_filter(params["types"])
    since = parse_int(params["since"])

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    # Replay events since sequence number
    if since do
      replay_events(conn, since, types_filter)
    end

    EventStream.subscribe()
    sse_loop(conn, nil, types_filter)
  end

  @doc """
  GET /api/v2/ag-ui/events/:agent_id

  SSE endpoint streaming events for a specific agent.
  """
  def stream_agent_events(conn, %{"agent_id" => agent_id} = params) do
    types_filter = parse_types_filter(params["types"])

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    # Send initial state snapshot for this agent
    case StateManager.get_state(agent_id) do
      nil -> :ok
      state ->
        snapshot = EventStream.emit_state_snapshot(%{agent_id: agent_id, state: state})
        send_sse(conn, snapshot)
    end

    EventStream.subscribe()
    sse_loop(conn, agent_id, types_filter)
  end

  @doc """
  GET /api/v2/ag-ui/state/:agent_id

  Returns the current state for an agent.
  """
  def get_state(conn, %{"agent_id" => agent_id}) do
    case StateManager.get_state_versioned(agent_id) do
      {state, version} ->
        json(conn, %{agent_id: agent_id, state: state, version: version})

      nil ->
        conn
        |> put_status(404)
        |> json(%{error: "No state for agent: #{agent_id}"})
    end
  end

  @doc """
  PUT /api/v2/ag-ui/state/:agent_id

  Sets the full state for an agent (snapshot).
  """
  def set_state(conn, %{"agent_id" => agent_id, "state" => state}) when is_map(state) do
    :ok = StateManager.set_state(agent_id, state)
    json(conn, %{ok: true, agent_id: agent_id})
  end

  def set_state(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "Missing required field: state (must be a map)"})
  end

  @doc """
  PATCH /api/v2/ag-ui/state/:agent_id

  Applies JSON Patch operations to an agent's state.
  """
  def patch_state(conn, %{"agent_id" => agent_id, "operations" => ops}) when is_list(ops) do
    case StateManager.apply_delta(agent_id, ops) do
      {:ok, new_state} ->
        json(conn, %{ok: true, agent_id: agent_id, state: new_state})

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{error: "Patch failed: #{inspect(reason)}"})
    end
  end

  def patch_state(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "Missing required field: operations (must be a list)"})
  end

  @doc """
  GET /api/v2/ag-ui/router/stats

  Returns event routing statistics.
  """
  def router_stats(conn, _params) do
    stats = EventRouter.stats()
    json(conn, stats)
  end

  # -- Private ----------------------------------------------------------------

  defp sse_loop(conn, agent_filter, types_filter) do
    receive do
      {:ag_ui_event, event} ->
        if should_send?(event, agent_filter, types_filter) do
          case send_sse(conn, event) do
            {:ok, conn} -> sse_loop(conn, agent_filter, types_filter)
            {:error, _} -> conn
          end
        else
          sse_loop(conn, agent_filter, types_filter)
        end
    after
      15_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> sse_loop(conn, agent_filter, types_filter)
          {:error, _} -> conn
        end
    end
  end

  defp should_send?(_event, nil, nil), do: true

  defp should_send?(event, agent_id, nil) when is_binary(agent_id) do
    event_agent = get_in(event, [:data, :agent_id])
    is_nil(event_agent) or event_agent == agent_id
  end

  defp should_send?(event, nil, types) when is_list(types) do
    event.type in types
  end

  defp should_send?(event, agent_id, types) do
    should_send?(event, agent_id, nil) and should_send?(event, nil, types)
  end

  defp send_sse(conn, event) do
    json_data = Jason.encode!(event)
    sse_payload = "id: #{event[:sequence] || 0}\nevent: #{event[:type] || "message"}\ndata: #{json_data}\n\n"
    chunk(conn, sse_payload)
  end

  defp replay_events(conn, since, types_filter) do
    events = EventStream.get_events(nil, 500)

    events
    |> Enum.filter(fn e -> e.sequence > since end)
    |> Enum.filter(fn e -> is_nil(types_filter) or e.type in types_filter end)
    |> Enum.reverse()
    |> Enum.each(fn event -> send_sse(conn, event) end)
  end

  defp parse_types_filter(nil), do: nil
  defp parse_types_filter(""), do: nil

  defp parse_types_filter(types_str) do
    types_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_int(nil), do: nil
  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> map
  end
end
