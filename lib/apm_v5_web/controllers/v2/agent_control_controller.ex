defmodule ApmV5Web.V2.AgentControlController do
  @moduledoc """
  V2 REST controller for agent connect/disconnect/restart actions.

  Provides POST /api/v2/agents/:id/connect|disconnect|restart endpoints
  used by CCEMAgent and the dashboard control panel.
  """

  use ApmV5Web, :controller

  @pubsub ApmV5.PubSub

  @valid_actions ["connect", "disconnect", "restart", "stop", "pause", "resume"]

  @doc "POST /api/v2/agents/:id/control — control an individual agent"
  def control_agent(conn, %{"id" => agent_id, "action" => action}) when action in @valid_actions do
    case ApmV5.AgentRegistry.get_agent(agent_id) do
      {:ok, agent} ->
        result = execute_control(agent_id, action, agent)
        emit_control_event("agent", agent_id, action)
        json(conn, %{ok: true, agent_id: agent_id, action: action, result: result})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Agent not found", agent_id: agent_id})
    end
  end

  def control_agent(conn, %{"id" => _id, "action" => action}) do
    conn |> put_status(:bad_request) |> json(%{error: "Invalid action: #{action}", valid: @valid_actions})
  end

  def control_agent(conn, %{"id" => _id}) do
    conn |> put_status(:bad_request) |> json(%{error: "action is required", valid: @valid_actions})
  end

  @doc "POST /api/v2/formations/:id/control — control a formation"
  def control_formation(conn, %{"id" => formation_id, "action" => action}) when action in @valid_actions do
    agents = get_formation_agents(formation_id)
    results = Enum.map(agents, fn agent ->
      agent_id = agent[:id] || agent["id"]
      result = execute_control(agent_id, action, agent)
      %{agent_id: agent_id, result: result}
    end)

    emit_control_event("formation", formation_id, action)
    json(conn, %{ok: true, formation_id: formation_id, action: action, agents: results, count: length(results)})
  end

  def control_formation(conn, %{"id" => _id}) do
    conn |> put_status(:bad_request) |> json(%{error: "action is required", valid: @valid_actions})
  end

  @doc "POST /api/v2/squadrons/:id/control — control a squadron"
  def control_squadron(conn, %{"id" => squadron_id, "action" => action}) when action in @valid_actions do
    agents = get_squadron_agents(squadron_id)
    results = Enum.map(agents, fn agent ->
      agent_id = agent[:id] || agent["id"]
      result = execute_control(agent_id, action, agent)
      %{agent_id: agent_id, result: result}
    end)

    emit_control_event("squadron", squadron_id, action)
    json(conn, %{ok: true, squadron_id: squadron_id, action: action, agents: results, count: length(results)})
  end

  def control_squadron(conn, %{"id" => _id}) do
    conn |> put_status(:bad_request) |> json(%{error: "action is required", valid: @valid_actions})
  end

  @doc "GET /api/v2/agents/:id/messages — get messages for an agent"
  def list_messages(conn, %{"id" => agent_id} = params) do
    limit = params |> Map.get("limit", "50") |> String.to_integer() |> min(500)
    scope = "agent:#{agent_id}"
    messages = ApmV5.ChatStore.list_messages(scope, limit)
    json(conn, %{data: messages, agent_id: agent_id, total: length(messages)})
  end

  @doc "POST /api/v2/agents/:id/messages — send message to an agent"
  def send_message(conn, %{"id" => agent_id, "content" => content} = params) do
    scope = "agent:#{agent_id}"
    metadata = Map.merge(Map.take(params, ["role"]), %{"agent_id" => agent_id})

    case ApmV5.ChatStore.send_message(scope, content, metadata) do
      {:ok, message} ->
        conn |> put_status(:created) |> json(%{data: message})
    end
  end

  def send_message(conn, %{"id" => _id}) do
    conn |> put_status(:bad_request) |> json(%{error: "content is required"})
  end

  # --- Private ---

  defp execute_control(agent_id, action, _agent) do
    new_status = case action do
      "connect" -> "active"
      "disconnect" -> "offline"
      "restart" -> "active"
      "stop" -> "offline"
      "pause" -> "idle"
      "resume" -> "active"
    end

    # Update agent status in registry
    try do
      ApmV5.AgentRegistry.update_agent(agent_id, %{status: new_status})
    rescue
      _ -> :ok
    end

    # Emit AG-UI event
    try do
      event_type = case action do
        "connect" -> "RUN_STARTED"
        "disconnect" -> "RUN_FINISHED"
        "restart" -> "RUN_STARTED"
        "stop" -> "RUN_FINISHED"
        "pause" -> "STEP_FINISHED"
        "resume" -> "STEP_STARTED"
      end

      ApmV5.EventStream.emit(event_type, %{
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
      %{resource_type: resource_type, resource_id: resource_id, action: action,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()}
    })

    # Also send notification
    try do
      ApmV5.AgentRegistry.add_notification(%{
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
    ApmV5.AgentRegistry.list_agents()
    |> Enum.filter(fn agent ->
      (agent[:formation_id] || agent["formation_id"]) == formation_id
    end)
  end

  defp get_squadron_agents(squadron_id) do
    ApmV5.AgentRegistry.list_agents()
    |> Enum.filter(fn agent ->
      (agent[:squadron_id] || agent["squadron_id"]) == squadron_id
    end)
  end
end
