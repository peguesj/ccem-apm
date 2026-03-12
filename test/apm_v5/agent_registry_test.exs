defmodule ApmV5.AgentRegistryTest do
  use ExUnit.Case, async: false

  alias ApmV5.AgentRegistry

  setup do
    ApmV5.GenServerHelpers.ensure_processes_alive()
    AgentRegistry.clear_all()
    :ok
  end

  describe "agent management" do
    test "register_agent/2 stores agent and get_agent/1 retrieves it" do
      :ok = AgentRegistry.register_agent("agent-1", %{name: "Orchestrator", tier: 1, status: "idle"})

      agent = AgentRegistry.get_agent("agent-1")
      assert agent.id == "agent-1"
      assert agent.name == "Orchestrator"
      assert agent.tier == 1
      assert agent.status == "idle"
      assert agent.deps == []
      assert is_binary(agent.registered_at)
    end

    test "register_agent/2 with defaults" do
      :ok = AgentRegistry.register_agent("agent-2")

      agent = AgentRegistry.get_agent("agent-2")
      assert agent.name == "agent-2"
      assert agent.tier == 1
      assert agent.status == "idle"
    end

    test "get_agent/1 returns nil for unknown agent" do
      assert AgentRegistry.get_agent("nonexistent") == nil
    end

    test "list_agents/0 returns all registered agents" do
      :ok = AgentRegistry.register_agent("a1", %{name: "Agent A"})
      :ok = AgentRegistry.register_agent("a2", %{name: "Agent B"})
      :ok = AgentRegistry.register_agent("a3", %{name: "Agent C"})

      agents = AgentRegistry.list_agents()
      assert length(agents) == 3
      names = Enum.map(agents, & &1.name) |> Enum.sort()
      assert names == ["Agent A", "Agent B", "Agent C"]
    end

    test "update_status/2 changes agent status and updates last_seen" do
      :ok = AgentRegistry.register_agent("agent-1", %{name: "Worker", status: "idle"})
      agent_before = AgentRegistry.get_agent("agent-1")

      # Small delay to ensure timestamp differs
      Process.sleep(10)
      :ok = AgentRegistry.update_status("agent-1", "active")

      agent_after = AgentRegistry.get_agent("agent-1")
      assert agent_after.status == "active"
      assert agent_after.last_seen >= agent_before.last_seen
    end

    test "update_status/2 returns error for unknown agent" do
      assert {:error, :not_found} = AgentRegistry.update_status("ghost", "active")
    end
  end

  describe "session management" do
    test "register_session/1 and get_session/1" do
      :ok = AgentRegistry.register_session(%{session_id: "sess-001", project: "apm-v5"})

      session = AgentRegistry.get_session("sess-001")
      assert session.session_id == "sess-001"
      assert session.project == "apm-v5"
      assert session.status == "active"
    end

    test "get_session/1 returns nil for unknown session" do
      assert AgentRegistry.get_session("nonexistent") == nil
    end

    test "list_sessions/0 returns all sessions" do
      :ok = AgentRegistry.register_session(%{session_id: "s1", project: "proj-a"})
      :ok = AgentRegistry.register_session(%{session_id: "s2", project: "proj-b"})

      sessions = AgentRegistry.list_sessions()
      assert length(sessions) == 2
      ids = Enum.map(sessions, & &1.session_id) |> Enum.sort()
      assert ids == ["s1", "s2"]
    end
  end

  describe "notification management" do
    test "add_notification/1 returns incrementing IDs" do
      id1 = AgentRegistry.add_notification(%{title: "First", message: "Hello"})
      id2 = AgentRegistry.add_notification(%{title: "Second", message: "World"})

      assert id1 == 1
      assert id2 == 2
    end

    test "get_notifications/0 returns notifications in reverse chronological order" do
      AgentRegistry.add_notification(%{title: "First", message: "msg1"})
      AgentRegistry.add_notification(%{title: "Second", message: "msg2"})
      AgentRegistry.add_notification(%{title: "Third", message: "msg3"})

      notifications = AgentRegistry.get_notifications()
      assert length(notifications) == 3
      titles = Enum.map(notifications, & &1.title)
      assert titles == ["Third", "Second", "First"]
    end

    test "clear_notifications/0 removes all notifications" do
      AgentRegistry.add_notification(%{title: "Test", message: "data"})
      AgentRegistry.add_notification(%{title: "Test2", message: "data2"})

      assert length(AgentRegistry.get_notifications()) == 2

      :ok = AgentRegistry.clear_notifications()
      assert AgentRegistry.get_notifications() == []
    end

    test "notification includes expected fields" do
      AgentRegistry.add_notification(%{title: "Alert", message: "Something happened", level: "warning"})

      [notif] = AgentRegistry.get_notifications()
      assert notif.title == "Alert"
      assert notif.message == "Something happened"
      assert notif.level == "warning"
      assert notif.read == false
      assert is_binary(notif.timestamp)
      assert is_integer(notif.id)
    end

    test "notifications capped at 200" do
      for i <- 1..210 do
        AgentRegistry.add_notification(%{title: "Notif #{i}", message: "msg"})
      end

      notifications = AgentRegistry.get_notifications()
      assert length(notifications) == 200
    end
  end
end
