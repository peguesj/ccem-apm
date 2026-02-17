defmodule ApmV4Web.AgentChannelTest do
  use ApmV4Web.ChannelCase

  alias ApmV4.AgentRegistry

  setup do
    # Ensure AgentRegistry is clean
    if Process.whereis(AgentRegistry), do: AgentRegistry.clear_all()

    {:ok, _, socket} =
      ApmV4Web.UserSocket
      |> socket(%{})
      |> subscribe_and_join(ApmV4Web.AgentChannel, "agent:fleet")

    %{socket: socket}
  end

  test "joining agent:fleet sends agent_list", %{socket: _socket} do
    assert_push "agent_list", %{agents: agents}
    assert is_list(agents)
  end

  test "receives agent_registered on new registration", %{socket: _socket} do
    # Wait for initial push
    assert_push "agent_list", _

    AgentRegistry.register_agent("test-agent-1", %{name: "Test Agent"}, nil)

    assert_push "agent_registered", %{agent: agent}
    assert agent.id == "test-agent-1"
  end

  test "receives agent_updated on status change", %{socket: _socket} do
    assert_push "agent_list", _

    AgentRegistry.register_agent("test-agent-2", %{name: "Test Agent 2"}, nil)
    assert_push "agent_registered", _

    AgentRegistry.update_status("test-agent-2", "running")
    assert_push "agent_updated", %{agent: agent}
    assert agent.status == "running"
  end

  test "joining agent:{id} sends agent_detail" do
    AgentRegistry.register_agent("specific-agent", %{name: "Specific"}, nil)

    {:ok, _, _socket} =
      ApmV4Web.UserSocket
      |> socket(%{})
      |> subscribe_and_join(ApmV4Web.AgentChannel, "agent:specific-agent")

    assert_push "agent_detail", %{agent: agent}
    assert agent.id == "specific-agent"
  end

  test "agent:{id} forwards updates for that specific agent" do
    AgentRegistry.register_agent("agent-a", %{name: "A"}, nil)

    {:ok, _, _agent_socket} =
      ApmV4Web.UserSocket
      |> socket(%{})
      |> subscribe_and_join(ApmV4Web.AgentChannel, "agent:agent-a")

    assert_push "agent_detail", _

    AgentRegistry.update_status("agent-a", "running")
    assert_push "agent_updated", %{agent: %{id: "agent-a", status: "running"}}
  end

  test "send_command replies with error when agent not found" do
    {:ok, _, cmd_socket} =
      ApmV4Web.UserSocket
      |> socket(%{})
      |> subscribe_and_join(ApmV4Web.AgentChannel, "agent:nonexistent")

    assert_push "agent_detail", _

    ref = push(cmd_socket, "send_command", %{"command" => "status"})
    assert_reply ref, :error, %{reason: _}
  end

  test "send_command replies ok when agent has a path" do
    AgentRegistry.register_agent("cmd-agent", %{name: "Cmd", path: "/tmp/test"}, nil)

    {:ok, _, cmd_socket} =
      ApmV4Web.UserSocket
      |> socket(%{})
      |> subscribe_and_join(ApmV4Web.AgentChannel, "agent:cmd-agent")

    assert_push "agent_detail", _

    ref = push(cmd_socket, "send_command", %{"command" => "status"})
    assert_reply ref, :ok, %{}
  end
end
