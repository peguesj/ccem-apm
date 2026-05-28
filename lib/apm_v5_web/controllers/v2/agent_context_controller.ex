defmodule ApmV5Web.V2.AgentContextController do
  @moduledoc """
  REST endpoints for real-time agent context (v8.4.0).

  GET /api/v2/agents/contexts          — all contexts (map of agent_id => context)
  GET /api/v2/agents/:id/context       — context for a specific agent
  GET /api/v2/agents/:id/context/events — recent AG-UI events for an agent
  """

  use ApmV5Web, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmV5Web.Plugs.OpenApiErrorRenderer

  alias ApmV5.AgUi.AgentContextStore
  alias ApmV5.AgUi.ToolCallTracker
  alias ApmV5Web.Schemas

  @doc "Returns all agent contexts."
  operation :index,
    summary: "List",
    tags: ["Agent Context"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def index(conn, _params) do
    contexts = AgentContextStore.list_contexts()
    json(conn, %{contexts: contexts})
  end

  @doc "Returns context for a specific agent."
  operation :show,
    summary: "Get one",
    tags: ["Agent Context"],
    responses: [
      ok: {"OK", "application/json", Schemas.AgentContext}
    ]

  def show(conn, %{"id" => agent_id}) do
    context = AgentContextStore.get_context(agent_id)
    tool_calls = ToolCallTracker.list_by_agent(agent_id) |> Enum.take(10)

    json(conn, %{
      agent_id: agent_id,
      context: context,
      activity_label: AgentContextStore.activity_label(agent_id),
      recent_tool_calls: Enum.map(tool_calls, &serialize_tool_call/1)
    })
  end

  @doc "Returns recent AG-UI events for a specific agent."
  operation :events,
    summary: "Events",
    tags: ["Agent Context"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def events(conn, %{"id" => agent_id} = params) do
    limit = Map.get(params, "limit", "10") |> String.to_integer() |> min(50)
    events = AgentContextStore.recent_events(agent_id, limit)
    json(conn, %{agent_id: agent_id, events: events, count: length(events)})
  end

  # -- Private ----------------------------------------------------------------

  defp serialize_tool_call(tc) do
    %{
      tool_call_id: tc.tool_call_id,
      tool_name: tc.tool_name,
      status: tc.status,
      started_at: tc.started_at_wall,
      duration_ms: tc.duration_ms
    }
  end
end
