defmodule ApmWeb.V2.AgentControlController do
  @moduledoc """
  V2 REST controller for agent connect/disconnect/restart actions.

  Provides POST /api/v2/agents/:id/connect|disconnect|restart endpoints
  used by CCEMHelper and the dashboard control panel.

  ## open_api_spex annotations (api-s5 Wave 1 / CP-262)
  Actions annotated: control_agent, list_messages, send_message (3 of many).
  Formation/squadron control actions documented via build_spec/0 until api-s7 (v9.4.0).
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s5 Wave 1: validate requests for annotated actions only.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmWeb.Plugs.OpenApiErrorRenderer

  alias ApmWeb.Schemas

  @pubsub Apm.PubSub

  @valid_actions ["connect", "disconnect", "restart", "stop", "pause", "resume"]

  operation(:control_agent,
    summary: "Control an agent",
    description:
      "Sends a lifecycle control action to an individual agent (connect, disconnect, restart, stop, pause, resume).",
    tags: ["Agents"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Agent ID"]
    ],
    request_body:
      {"Control action", "application/json", Schemas.ControlAgentBody, required: true},
    responses: [
      ok: {"Control result", "application/json", Schemas.ControlAgentResult},
      not_found: {"Agent not found", "application/json", Schemas.ErrorResponse},
      bad_request: {"Invalid action", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:list_messages,
    summary: "List agent messages",
    description: "Returns recent messages in the agent's chat channel.",
    tags: ["Agents"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Agent ID"],
      limit: [
        in: :query,
        type: :integer,
        required: false,
        description: "Max messages to return (default 50, max 500)"
      ]
    ],
    responses: [
      ok: {"Message list", "application/json", Schemas.MessageList}
    ]
  )

  operation(:send_message,
    summary: "Send message to agent",
    description: "Posts a message to the agent's chat channel and broadcasts via PubSub.",
    tags: ["Agents"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Agent ID"]
    ],
    request_body: {"Message body", "application/json", Schemas.SendMessageBody, required: true},
    responses: [
      created: {"Message created", "application/json", Schemas.ChatMessage},
      bad_request: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]
  )

  @doc "POST /api/v2/agents/:id/control — control an individual agent"
  def control_agent(conn, %{"id" => agent_id, "action" => action})
      when action in @valid_actions do
    case Apm.AgentRegistry.get_agent(agent_id) do
      {:ok, agent} ->
        result = execute_control(agent_id, action, agent)
        emit_control_event("agent", agent_id, action)
        json(conn, %{ok: true, agent_id: agent_id, action: action, result: result})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Agent not found", agent_id: agent_id})
    end
  end

  def control_agent(conn, %{"id" => _id, "action" => action}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Invalid action: #{action}", valid: @valid_actions})
  end

  def control_agent(conn, %{"id" => _id}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "action is required", valid: @valid_actions})
  end

  @doc "POST /api/v2/formations/:id/control — control a formation"
  operation(:control_formation,
    summary: "Control formation",
    tags: ["Agents"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def control_formation(conn, %{"id" => formation_id, "action" => action})
      when action in @valid_actions do
    agents = get_formation_agents(formation_id)

    results =
      Enum.map(agents, fn agent ->
        agent_id = agent[:id] || agent["id"]
        result = execute_control(agent_id, action, agent)
        %{agent_id: agent_id, result: result}
      end)

    emit_control_event("formation", formation_id, action)

    json(conn, %{
      ok: true,
      formation_id: formation_id,
      action: action,
      agents: results,
      count: length(results)
    })
  end

  def control_formation(conn, %{"id" => _id}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "action is required", valid: @valid_actions})
  end

  @doc "POST /api/v2/squadrons/:id/control — control a squadron"
  operation(:control_squadron,
    summary: "Control squadron",
    tags: ["Agents"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def control_squadron(conn, %{"id" => squadron_id, "action" => action})
      when action in @valid_actions do
    agents = get_squadron_agents(squadron_id)

    results =
      Enum.map(agents, fn agent ->
        agent_id = agent[:id] || agent["id"]
        result = execute_control(agent_id, action, agent)
        %{agent_id: agent_id, result: result}
      end)

    emit_control_event("squadron", squadron_id, action)

    json(conn, %{
      ok: true,
      squadron_id: squadron_id,
      action: action,
      agents: results,
      count: length(results)
    })
  end

  def control_squadron(conn, %{"id" => _id}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "action is required", valid: @valid_actions})
  end

  @doc "GET /api/v2/agents/:id/messages — get messages for an agent"
  def list_messages(conn, %{"id" => agent_id} = params) do
    limit = params |> Map.get("limit", "50") |> String.to_integer() |> min(500)
    scope = "agent:#{agent_id}"
    messages = Apm.ChatStore.list_messages(scope, limit)
    json(conn, %{data: messages, agent_id: agent_id, total: length(messages)})
  end

  @doc "POST /api/v2/agents/:id/messages — send message to an agent"
  def send_message(conn, %{"id" => agent_id, "content" => content} = params) do
    scope = "agent:#{agent_id}"
    metadata = Map.merge(Map.take(params, ["role"]), %{"agent_id" => agent_id})

    case Apm.ChatStore.send_message(scope, content, metadata) do
      {:ok, message} ->
        conn |> put_status(:created) |> json(%{data: message})
    end
  end

  def send_message(conn, %{"id" => _id}) do
    conn |> put_status(:bad_request) |> json(%{error: "content is required"})
  end

  # --- Private ---

  defp execute_control(agent_id, action, _agent) do
    new_status =
      case action do
        "connect" -> "active"
        "disconnect" -> "offline"
        "restart" -> "active"
        "stop" -> "offline"
        "pause" -> "idle"
        "resume" -> "active"
      end

    # Update agent status in registry
    try do
      Apm.AgentRegistry.update_agent(agent_id, %{status: new_status})
    rescue
      _ -> :ok
    end

    # Emit AG-UI event
    try do
      event_type =
        case action do
          "connect" -> "RUN_STARTED"
          "disconnect" -> "RUN_FINISHED"
          "restart" -> "RUN_STARTED"
          "stop" -> "RUN_FINISHED"
          "pause" -> "STEP_FINISHED"
          "resume" -> "STEP_STARTED"
        end

      Apm.EventStream.emit(event_type, %{
        agent_id: agent_id,
        action: action,
        source: "control_panel"
      })
    rescue
      _ -> :ok
    end

    new_status
  end

  defp emit_control_event(resource_type, resource_id, action) do
    Phoenix.PubSub.broadcast(@pubsub, "apm:control", {
      :control_event,
      %{
        resource_type: resource_type,
        resource_id: resource_id,
        action: action,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    })

    # Also send notification
    try do
      Apm.AgentRegistry.add_notification(%{
        type: "info",
        title: "#{String.capitalize(resource_type)} #{action}",
        message: "#{resource_type} #{resource_id}: #{action}",
        category: "agent",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })
    rescue
      _ -> :ok
    end
  end

  defp get_formation_agents(formation_id) do
    Apm.AgentRegistry.list_agents()
    |> Enum.filter(fn agent ->
      (agent[:formation_id] || agent["formation_id"]) == formation_id
    end)
  end

  defp get_squadron_agents(squadron_id) do
    Apm.AgentRegistry.list_agents()
    |> Enum.filter(fn agent ->
      (agent[:squadron_id] || agent["squadron_id"]) == squadron_id
    end)
  end

  # api-s5 Wave 1: catch-all for non-annotated actions.
  def open_api_operation(_action), do: nil
end
