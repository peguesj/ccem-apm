defmodule ApmV5Web.V2.ToolCallController do
  @moduledoc """
  REST + SSE endpoints for tool call data.

  ## US-012 Acceptance Criteria (DoD):
  - GET /api/v2/tool-calls returns active tool calls
  - GET /api/v2/tool-calls/:id returns specific tool call
  - GET /api/v2/tool-calls/agent/:agent_id returns agent history
  - GET /api/v2/tool-calls/stats returns aggregate statistics

  ## US-013 Acceptance Criteria (DoD):
  - GET /api/v2/tool-calls/stream SSE endpoint with EventBus 'tool:*' subscription
  - Supports ?agent_id and ?tool_name query params for filtering
  - Keepalive comments every 15 seconds
  - Handles client disconnection gracefully
  - mix compile --warnings-as-errors passes
  """

  use ApmV5Web, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmV5Web.Plugs.OpenApiErrorRenderer

  alias ApmV5.AgUi.ToolCallTracker
  alias ApmV5.AgUi.EventBus
  alias ApmV5Web.Schemas

  # -- REST Endpoints (US-012) ------------------------------------------------

  @doc "GET /api/v2/tool-calls - List active tool calls."
  operation :index,
    summary: "List",
    tags: ["Tool Calls"],
    responses: [
      ok: {"Active tool calls", "application/json", Schemas.ToolCallSummary}
    ]

  def index(conn, _params) do
    json(conn, %{tool_calls: ToolCallTracker.list_active()})
  end

  @doc "GET /api/v2/tool-calls/stats - Aggregate tool call statistics."
  operation :stats,
    summary: "Statistics",
    tags: ["Tool Calls"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def stats(conn, _params) do
    json(conn, ToolCallTracker.stats())
  end

  @doc "GET /api/v2/tool-calls/agent/:agent_id - Tool call history for an agent."
  operation :by_agent,
    summary: "By agent",
    tags: ["Tool Calls"],
    responses: [
      ok: {"Tool calls by agent", "application/json", Schemas.ToolCallSummary}
    ]

  def by_agent(conn, %{"agent_id" => agent_id}) do
    json(conn, %{tool_calls: ToolCallTracker.list_by_agent(agent_id)})
  end

  @doc "GET /api/v2/tool-calls/:id - Specific tool call by ID."
  operation :show,
    summary: "Get one",
    tags: ["Tool Calls"],
    responses: [
      ok: {"Single tool call", "application/json", Schemas.ToolCallSummary}
    ]

  def show(conn, %{"id" => id}) do
    case ToolCallTracker.get(id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "Tool call not found"})

      tool_call ->
        json(conn, tool_call)
    end
  end

  # -- SSE Streaming (US-013) -------------------------------------------------

  @doc "GET /api/v2/tool-calls/stream - SSE endpoint for real-time tool call events."
  operation :stream,
    summary: "Stream",
    tags: ["Tool Calls"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def stream(conn, params) do
    agent_filter = params["agent_id"]
    tool_filter = params["tool_name"]

    EventBus.subscribe("tool:*")

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("access-control-allow-origin", "*")
      |> send_chunked(200)

    # Send initial data
    {:ok, conn} = chunk(conn, ": connected\n\n")

    stream_loop(conn, agent_filter, tool_filter)
  end

  # -- Private ----------------------------------------------------------------

  defp stream_loop(conn, agent_filter, tool_filter) do
    receive do
      {:event_bus, _topic, %{type: type, data: data}}
      when type in ["TOOL_CALL_START", "TOOL_CALL_ARGS", "TOOL_CALL_END", "TOOL_CALL_RESULT"] ->
        if matches_filter?(data, agent_filter, tool_filter) do
          payload = Jason.encode!(%{type: type, data: data})

          case chunk(conn, "event: #{type}\ndata: #{payload}\n\n") do
            {:ok, conn} -> stream_loop(conn, agent_filter, tool_filter)
            {:error, _} -> conn
          end
        else
          stream_loop(conn, agent_filter, tool_filter)
        end

      {:event_bus, _topic, _event} ->
        stream_loop(conn, agent_filter, tool_filter)
    after
      15_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> stream_loop(conn, agent_filter, tool_filter)
          {:error, _} -> conn
        end
    end
  end

  defp matches_filter?(data, agent_filter, tool_filter) do
    agent_match = is_nil(agent_filter) or data[:agent_id] == agent_filter
    tool_match = is_nil(tool_filter) or data[:tool_name] == tool_filter
    agent_match and tool_match
  end
end
