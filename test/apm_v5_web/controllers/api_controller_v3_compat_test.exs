defmodule ApmV5Web.ApiControllerV3CompatTest do
  @moduledoc """
  Tests all 19 v3-compatible endpoints to ensure backward-compatible
  behavior for the v3 -> v4 cutover.
  """

  use ApmV5Web.ConnCase, async: false

  alias ApmV5.AgentRegistry
  alias ApmV5.ProjectStore

  setup do
    ApmV5.GenServerHelpers.ensure_processes_alive()
    AgentRegistry.clear_all()
    ProjectStore.clear_all()
    :ok
  end

  # ==========================================
  # GET /health
  # ==========================================

  describe "GET /api/status (health)" do
    test "returns status with expected fields", %{conn: conn} do
      conn = get(conn, ~p"/api/status")
      body = json_response(conn, 200)

      assert body["status"] == "ok"
      assert is_integer(body["uptime"])
      assert is_binary(body["server_version"])
    end
  end

  # ==========================================
  # GET /api/data
  # ==========================================

  describe "GET /api/data" do
    test "returns master aggregation with all expected fields", %{conn: conn} do
      conn = get(conn, ~p"/api/data")
      body = json_response(conn, 200)

      assert is_list(body["agents"])
      assert is_map(body["summary"])
      assert is_list(body["edges"])
      assert is_list(body["tasks"])
      assert is_list(body["notifications"])
      assert is_list(body["commands"])
      assert is_list(body["input_requests"])
    end

    test "includes registered agents in data", %{conn: conn} do
      AgentRegistry.register_agent("data-agent", %{name: "DataAgent", status: "active"})

      conn = get(conn, ~p"/api/data")
      body = json_response(conn, 200)

      assert length(body["agents"]) >= 1
      assert body["summary"]["total"] >= 1
      assert body["summary"]["active"] >= 1
    end

    test "accepts project query parameter", %{conn: conn} do
      AgentRegistry.register_agent("proj-agent", %{name: "ProjAgent"}, "my-project")

      conn = get(conn, ~p"/api/data?project=my-project")
      body = json_response(conn, 200)

      agent_names = Enum.map(body["agents"], & &1["name"])
      assert "ProjAgent" in agent_names
    end
  end

  # ==========================================
  # GET /api/notifications
  # ==========================================

  describe "GET /api/notifications" do
    test "returns empty notifications when none exist", %{conn: conn} do
      conn = get(conn, ~p"/api/notifications")
      body = json_response(conn, 200)

      # API returns paginated envelope: %{count, limit, notifications}
      assert is_map(body)
      assert is_list(body["notifications"])
    end

    test "returns notifications in envelope", %{conn: conn} do
      AgentRegistry.add_notification(%{title: "Test", message: "Hello", level: "info"})

      conn = get(conn, ~p"/api/notifications")
      body = json_response(conn, 200)

      assert body["count"] >= 1
      assert length(body["notifications"]) >= 1
    end
  end

  # ==========================================
  # POST /api/notifications/add
  # ==========================================

  describe "POST /api/notifications/add" do
    test "adds notification with v3 field names (body, category)", %{conn: conn} do
      payload = %{title: "LFG dtf", body: "Freed 2.5G", category: "success", agent_id: "lfg-dtf"}

      conn = post(conn, ~p"/api/notifications/add", payload)
      body = json_response(conn, 200)

      assert body["ok"] == true
      assert is_integer(body["id"])

      [notif] = AgentRegistry.get_notifications()
      assert notif.title == "LFG dtf"
      assert notif.message == "Freed 2.5G"
      assert notif.level == "success"
    end
  end

  # ==========================================
  # POST /api/notifications/read-all
  # ==========================================

  describe "POST /api/notifications/read-all" do
    test "marks all notifications as read", %{conn: conn} do
      AgentRegistry.add_notification(%{title: "N1", message: "m1"})
      AgentRegistry.add_notification(%{title: "N2", message: "m2"})

      conn = post(conn, ~p"/api/notifications/read-all")
      assert json_response(conn, 200)["ok"] == true

      notifs = AgentRegistry.get_notifications()
      assert Enum.all?(notifs, & &1.read)
    end
  end

  # ==========================================
  # GET /api/ralph
  # ==========================================

  describe "GET /api/ralph" do
    test "returns ralph data (may be empty)", %{conn: conn} do
      conn = get(conn, ~p"/api/ralph")
      body = json_response(conn, 200)

      # Should return some map (possibly empty if no prd_json configured)
      assert is_map(body)
    end
  end

  # ==========================================
  # GET /api/ralph/flowchart
  # ==========================================

  describe "GET /api/ralph/flowchart" do
    test "returns nodes and edges", %{conn: conn} do
      conn = get(conn, ~p"/api/ralph/flowchart")
      body = json_response(conn, 200)

      assert is_list(body["nodes"])
      assert is_list(body["edges"])
    end
  end

  # ==========================================
  # GET /api/commands
  # ==========================================

  describe "GET /api/commands" do
    test "returns empty list when no commands registered", %{conn: conn} do
      conn = get(conn, ~p"/api/commands")
      body = json_response(conn, 200)

      assert body == []
    end
  end

  # ==========================================
  # POST /api/commands
  # ==========================================

  describe "POST /api/commands" do
    test "registers commands and can retrieve them", %{conn: conn} do
      payload = %{
        project: "_global",
        commands: [
          %{name: "fix", description: "Fix loop"},
          %{name: "tdd", description: "TDD workflow"}
        ]
      }

      conn = post(conn, ~p"/api/commands", payload)
      body = json_response(conn, 200)

      assert body["ok"] == true
      assert body["count"] == 2
    end
  end

  # ==========================================
  # POST /api/agents/register (alias)
  # ==========================================

  describe "POST /api/agents/register" do
    test "registers agent via v3-compatible path", %{conn: conn} do
      payload = %{agent_id: "v3-agent", name: "V3 Agent", tier: 1, status: "active"}

      conn = post(conn, ~p"/api/agents/register", payload)
      body = json_response(conn, 201)

      assert body["ok"] == true
      assert body["agent_id"] == "v3-agent"
    end
  end

  # ==========================================
  # POST /api/agents/update
  # ==========================================

  describe "POST /api/agents/update" do
    test "updates agent fields", %{conn: conn} do
      AgentRegistry.register_agent("upd-agent", %{name: "Original", status: "idle"})

      payload = %{agent_id: "upd-agent", status: "active", name: "Updated"}
      conn = post(conn, ~p"/api/agents/update", payload)
      body = json_response(conn, 200)

      assert body["ok"] == true

      agent = AgentRegistry.get_agent("upd-agent")
      assert agent.status == "active"
      assert agent.name == "Updated"
    end

    test "returns 404 for unknown agent", %{conn: conn} do
      conn = post(conn, ~p"/api/agents/update", %{agent_id: "ghost", status: "active"})
      assert json_response(conn, 404)["error"] == "Agent not found"
    end
  end

  # ==========================================
  # GET /api/agents/discover
  # ==========================================

  describe "GET /api/agents/discover" do
    test "triggers discovery and returns result", %{conn: conn} do
      conn = get(conn, ~p"/api/agents/discover")
      body = json_response(conn, 200)

      assert is_list(body["discovered"])
      assert is_integer(body["count"])
    end
  end

  # ==========================================
  # GET /api/input/pending
  # ==========================================

  describe "GET /api/input/pending" do
    test "returns empty list when no input requests", %{conn: conn} do
      conn = get(conn, ~p"/api/input/pending")
      body = json_response(conn, 200)

      assert body == []
    end
  end

  # ==========================================
  # POST /api/input/request + POST /api/input/respond
  # ==========================================

  describe "input request/respond cycle" do
    test "creates input request and responds to it", %{conn: conn} do
      # Create input request
      payload = %{prompt: "Choose database", options: ["PostgreSQL", "SQLite", "MySQL"]}
      conn1 = post(conn, ~p"/api/input/request", payload)
      body1 = json_response(conn1, 200)

      assert body1["ok"] == true
      id = body1["id"]

      # Check it appears in pending
      conn2 = get(conn, ~p"/api/input/pending")
      pending = json_response(conn2, 200)
      assert length(pending) == 1

      # Respond to it
      conn3 = post(conn, ~p"/api/input/respond", %{id: id, choice: "SQLite"})
      body3 = json_response(conn3, 200)
      assert body3["ok"] == true

      # Should no longer be pending
      conn4 = get(conn, ~p"/api/input/pending")
      assert json_response(conn4, 200) == []
    end
  end

  # ==========================================
  # POST /api/tasks/sync
  # ==========================================

  describe "POST /api/tasks/sync" do
    test "syncs task list", %{conn: conn} do
      tasks = [
        %{id: "T1", subject: "Build UI", status: "pending"},
        %{id: "T2", subject: "Write tests", status: "in_progress"}
      ]

      conn = post(conn, ~p"/api/tasks/sync", %{tasks: tasks})
      body = json_response(conn, 200)

      assert body["ok"] == true
      assert body["count"] == 2
    end
  end

  # ==========================================
  # POST /api/config/reload
  # ==========================================

  describe "POST /api/config/reload" do
    test "reloads config and returns ok", %{conn: conn} do
      conn = post(conn, ~p"/api/config/reload")
      body = json_response(conn, 200)

      assert body["ok"] == true
    end
  end

  # ==========================================
  # POST /api/plane/update
  # ==========================================

  describe "POST /api/plane/update" do
    test "updates plane context", %{conn: conn} do
      payload = %{workspace: "my-workspace", project_id: "PROJ-123"}

      conn = post(conn, ~p"/api/plane/update", payload)
      body = json_response(conn, 200)

      assert body["ok"] == true
    end
  end

  # ==========================================
  # GET /api/projects (v4-only)
  # ==========================================

  describe "GET /api/projects" do
    test "returns projects list", %{conn: conn} do
      conn = get(conn, ~p"/api/projects")
      body = json_response(conn, 200)

      assert is_list(body["projects"])
      assert Map.has_key?(body, "active_project")
    end
  end

  # ==========================================
  # CORS headers
  # ==========================================

  describe "CORS headers" do
    test "API responses include CORS headers", %{conn: conn} do
      conn = get(conn, ~p"/api/status")

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["GET, POST, OPTIONS"]
    end
  end

  # ==========================================
  # Existing v4 endpoints still work
  # ==========================================

  describe "existing v4 endpoints backward compat" do
    test "GET /api/status still works", %{conn: conn} do
      conn = get(conn, ~p"/api/status")
      body = json_response(conn, 200)

      assert body["status"] == "ok"
      assert is_binary(body["server_version"])
    end

    test "POST /api/register still works", %{conn: conn} do
      conn = post(conn, ~p"/api/register", %{agent_id: "compat-test"})
      assert json_response(conn, 201)["ok"] == true
    end

    test "POST /api/heartbeat still works", %{conn: conn} do
      AgentRegistry.register_agent("hb-test", %{name: "HB"})

      conn = post(conn, ~p"/api/heartbeat", %{agent_id: "hb-test"})
      assert json_response(conn, 200)["ok"] == true
    end

    test "POST /api/notify still works", %{conn: conn} do
      conn = post(conn, ~p"/api/notify", %{title: "Test"})
      assert json_response(conn, 200)["ok"] == true
    end

    test "GET /api/agents still works", %{conn: conn} do
      conn = get(conn, ~p"/api/agents")
      assert json_response(conn, 200)["agents"] == []
    end
  end
end
