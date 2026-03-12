defmodule ApmV5Web.AgUiChannel do
  @moduledoc """
  WebSocket channel for bidirectional AG-UI communication.

  ## US-047 Acceptance Criteria (DoD):
  - Channel at "ag_ui:lobby" and "ag_ui:{agent_id}"
  - join/3 subscribes to EventBus topics for the agent
  - handle_in "emit" publishes to EventBus
  - handle_in "subscribe" adds EventBus subscription
  - handle_in "state:get" returns agent state
  - handle_in "state:patch" patches agent state
  - handle_in "a2a:send" sends an A2A message
  - EventBus events forwarded to client as push messages
  - mix compile --warnings-as-errors passes
  """

  use Phoenix.Channel

  alias ApmV5.AgUi.{EventBus, StateManager}
  alias ApmV5.AgUi.A2A.Router, as: A2ARouter

  @impl true
  def join("ag_ui:lobby", _payload, socket) do
    EventBus.subscribe("lifecycle:*")
    EventBus.subscribe("special:custom")
    {:ok, %{status: "connected", channel: "lobby"}, socket}
  end

  def join("ag_ui:" <> agent_id, _payload, socket) do
    EventBus.subscribe("lifecycle:*")
    EventBus.subscribe("state:#{agent_id}")
    EventBus.subscribe("a2a:#{agent_id}")

    socket = assign(socket, :agent_id, agent_id)
    {:ok, %{status: "connected", agent_id: agent_id}, socket}
  end

  @impl true
  def handle_in("emit", %{"type" => type} = payload, socket) do
    agent_id = payload["agent_id"] || socket.assigns[:agent_id] || "unknown"

    EventBus.publish(type, %{
      agent_id: agent_id,
      name: payload["name"],
      value: payload["value"] || payload["data"] || %{}
    })

    {:reply, {:ok, %{published: type}}, socket}
  end

  def handle_in("subscribe", %{"topic" => topic}, socket) do
    EventBus.subscribe(topic)
    {:reply, {:ok, %{subscribed: topic}}, socket}
  end

  def handle_in("state:get", %{"agent_id" => agent_id}, socket) do
    state = StateManager.get_state(agent_id)
    {:reply, {:ok, %{agent_id: agent_id, state: state}}, socket}
  end

  def handle_in("state:patch", %{"agent_id" => agent_id, "patch" => patch}, socket) do
    current = StateManager.get_state(agent_id) || %{}
    merged = Map.merge(current, patch)
    StateManager.set_state(agent_id, merged)
    {:reply, {:ok, %{agent_id: agent_id, patched: true}}, socket}
  end

  def handle_in("a2a:send", params, socket) do
    case A2ARouter.send(params) do
      {:ok, id} -> {:reply, {:ok, %{message_id: id}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "unknown event"}}, socket}
  end

  @impl true
  def handle_info({:event_bus, topic, event}, socket) do
    push(socket, "ag_ui:event", %{topic: topic, event: event})
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end
end
