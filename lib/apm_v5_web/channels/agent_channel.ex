defmodule ApmV5Web.AgentChannel do
  @moduledoc """
  Phoenix Channel for real-time agent event streaming.

  Handles connections on the `agent:*` topic. Broadcasts agent
  registration, heartbeat, and completion events to connected clients.
  """

  use ApmV5Web, :channel

  alias ApmV5.AgentRegistry

  @impl true
  def join("agent:fleet", _params, socket) do
    send(self(), :after_join)
    {:ok, socket}
  end

  def join("agent:" <> agent_id, _params, socket) do
    send(self(), :after_join)
    {:ok, assign(socket, :agent_id, agent_id)}
  end

  @impl true
  def handle_info(:after_join, %{topic: "agent:fleet"} = socket) do
    Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:agents")
    agents = AgentRegistry.list_agents()
    push(socket, "agent_list", %{agents: agents})
    {:noreply, socket}
  end

  def handle_info(:after_join, socket) do
    agent_id = socket.assigns.agent_id
    Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:agents")

    case AgentRegistry.get_agent(agent_id) do
      nil -> push(socket, "agent_detail", %{agent: nil})
      agent -> push(socket, "agent_detail", %{agent: agent})
    end

    {:noreply, socket}
  end

  def handle_info({:agent_registered, agent}, %{topic: "agent:fleet"} = socket) do
    push(socket, "agent_registered", %{agent: agent})
    {:noreply, socket}
  end

  def handle_info({:agent_updated, agent}, %{topic: "agent:fleet"} = socket) do
    push(socket, "agent_updated", %{agent: agent})
    {:noreply, socket}
  end

  def handle_info({:agent_registered, agent}, socket) do
    if agent.id == socket.assigns.agent_id do
      push(socket, "agent_registered", %{agent: agent})
    end

    {:noreply, socket}
  end

  def handle_info({:agent_updated, agent}, socket) do
    if agent.id == socket.assigns.agent_id do
      push(socket, "agent_updated", %{agent: agent})
    end

    {:noreply, socket}
  end

  @impl true
  def handle_in("send_command", %{"command" => command}, socket) do
    agent_id = socket.assigns[:agent_id]

    case agent_id && AgentRegistry.get_agent(agent_id) do
      %{path: path} when is_binary(path) and path != "" ->
        {:reply, {:ok, %{status: "command_received", agent_id: agent_id, command: command}}, socket}

      _ ->
        {:reply, {:error, %{reason: "agent not found or has no path"}}, socket}
    end
  end
end
