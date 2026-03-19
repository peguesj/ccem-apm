defmodule ApmV5Web.ApiControllerTest do
  use ApmV5Web.ConnCase, async: false

  alias ApmV5.AgentRegistry

  setup do
    ApmV5.GenServerHelpers.ensure_processes_alive()
    AgentRegistry.clear_all()
    :ok
  end

  describe "GET /api/status" do
    test "returns status with expected fields", %{conn: conn} do
      conn = get(conn, ~p"/api/status")
      body = json_response(conn, 200)

      assert body["status"] == "ok"
      assert is_integer(body["uptime"])
      assert body["agent_count"] == 0
      assert body["session_id"] == "none"
      assert is_binary(body["server_version"])
    end

    test "returns correct agent count after registrations", %{conn: conn} do
      AgentRegistry.register_agent("a1", %{name: "Agent1"})
      AgentRegistry.register_agent("a2", %{name: "Agent2"})

      conn = get(conn, ~p"/api/status")
      body = json_response(conn, 200)

      assert body["agent_count"] == 2
    end

    test "returns session_id when sessions exist", %{conn: conn} do
      AgentRegistry.register_session(%{session_id: "sess-123", project: "test"})

      conn = get(conn, ~p"/api/status")
      body = json_response(conn, 200)

      assert body["session_id"] == "sess-123"
    end
  end

  describe "POST /api/register" do
    test "registers a new agent with full payload", %{conn: conn} do
      payload = %{
        agent_id: "orchestrator-1",
        name: "Orchestrator",
        tier: 1,
        status: "active",
        deps: ["worker-1", "worker-2"],
        metadata: %{role: "coordinator"}
      }

      conn = post(conn, ~p"/api/register", payload)
      body = json_response(conn, 201)

      assert body["ok"] == true
      assert body["agent_id"] == "orchestrator-1"

      # Verify agent was stored
      agent = AgentRegistry.get_agent("orchestrator-1")
      assert agent.name == "Orchestrator"
      assert agent.tier == 1
      assert agent.status == "active"
      assert agent.deps == ["worker-1", "worker-2"]
    end

    test "registers agent with minimal payload (just id)", %{conn: conn} do
      conn = post(conn, ~p"/api/register", %{agent_id: "minimal-1"})
      body = json_response(conn, 201)

      assert body["ok"] == true

      agent = AgentRegistry.get_agent("minimal-1")
      assert agent.name == "minimal-1"
      assert agent.status == "idle"
    end

    test "accepts 'id' field as alternative to 'agent_id'", %{conn: conn} do
      conn = post(conn, ~p"/api/register", %{id: "alt-id-agent"})
      body = json_response(conn, 201)

      assert body["ok"] == true
      assert body["agent_id"] == "alt-id-agent"
    end

    test "returns 400 when agent_id is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/register", %{name: "No ID"})
      body = json_response(conn, 400)

      assert body["error"] =~ "Missing required field"
    end
  end

  describe "POST /api/heartbeat" do
    test "updates agent status and returns success", %{conn: conn} do
      AgentRegistry.register_agent("hb-agent", %{name: "Heartbeat Agent", status: "idle"})

      conn = post(conn, ~p"/api/heartbeat", %{agent_id: "hb-agent", status: "active"})
      body = json_response(conn, 200)

      assert body["ok"] == true
      assert body["agent_id"] == "hb-agent"

      agent = AgentRegistry.get_agent("hb-agent")
      assert agent.status == "active"
    end

    test "defaults to 'active' status when not provided", %{conn: conn} do
      AgentRegistry.register_agent("hb-agent-2", %{name: "Agent", status: "idle"})

      conn = post(conn, ~p"/api/heartbeat", %{agent_id: "hb-agent-2"})
      assert json_response(conn, 200)["ok"] == true

      agent = AgentRegistry.get_agent("hb-agent-2")
      assert agent.status == "active"
    end

    test "auto-registers unknown agent on heartbeat", %{conn: conn} do
      conn = post(conn, ~p"/api/heartbeat", %{agent_id: "ghost"})
      body = json_response(conn, 200)

      assert body["ok"] == true
    end

    test "returns 400 when agent_id is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/heartbeat", %{status: "active"})
      body = json_response(conn, 400)

      assert body["error"] =~ "Missing required field"
    end
  end

  describe "GET /api/agents" do
    test "returns empty agents list", %{conn: conn} do
      conn = get(conn, ~p"/api/agents")
      body = json_response(conn, 200)

      assert body["agents"] == []
    end

    test "returns all registered agents with metadata", %{conn: conn} do
      AgentRegistry.register_agent("a1", %{name: "Alpha", tier: 1, status: "active"})
      AgentRegistry.register_agent("a2", %{name: "Beta", tier: 2, status: "idle"})

      conn = get(conn, ~p"/api/agents")
      body = json_response(conn, 200)

      assert length(body["agents"]) == 2
      names = Enum.map(body["agents"], & &1["name"]) |> Enum.sort()
      assert names == ["Alpha", "Beta"]
    end
  end

  describe "POST /api/notify" do
    test "creates a notification with full payload", %{conn: conn} do
      payload = %{title: "Build Complete", message: "All tests passed", level: "info"}
      conn = post(conn, ~p"/api/notify", payload)
      body = json_response(conn, 200)

      assert body["ok"] == true
      assert is_integer(body["id"])

      [notif] = AgentRegistry.get_notifications()
      assert notif.title == "Build Complete"
      assert notif.message == "All tests passed"
      assert notif.level == "info"
    end

    test "creates notification with defaults when fields missing", %{conn: conn} do
      conn = post(conn, ~p"/api/notify", %{})
      body = json_response(conn, 200)

      assert body["ok"] == true

      [notif] = AgentRegistry.get_notifications()
      assert notif.title == "Notification"
      assert notif.message == ""
      assert notif.level == "info"
    end
  end

  describe "content type" do
    test "all endpoints return JSON content type", %{conn: conn} do
      conn1 = get(conn, ~p"/api/status")
      assert get_resp_header(conn1, "content-type") |> List.first() =~ "application/json"

      conn2 = get(conn, ~p"/api/agents")
      assert get_resp_header(conn2, "content-type") |> List.first() =~ "application/json"

      conn3 = post(conn, ~p"/api/notify", %{title: "Test"})
      assert get_resp_header(conn3, "content-type") |> List.first() =~ "application/json"
    end
  end
end
