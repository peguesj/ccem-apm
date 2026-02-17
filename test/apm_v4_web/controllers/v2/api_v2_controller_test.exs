defmodule ApmV4Web.V2.ApiV2ControllerTest do
  use ApmV4Web.ConnCase, async: false

  alias ApmV4.AgentRegistry
  alias ApmV4.MetricsCollector
  alias ApmV4.SloEngine
  alias ApmV4.AlertRulesEngine
  alias ApmV4.AuditLog

  setup do
    AgentRegistry.clear_all()
    MetricsCollector.clear_all()
    SloEngine.clear_all()
    GenServer.call(AlertRulesEngine, :reinit)
    :ok
  end

  # ========== Agents ==========

  describe "GET /api/v2/agents" do
    test "returns envelope with data array and meta", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/agents")
      body = json_response(conn, 200)

      assert is_list(body["data"])
      assert is_map(body["meta"])
      assert body["meta"]["total"] == 0
      assert body["meta"]["has_more"] == false
      assert is_map(body["links"])
    end

    test "returns registered agents", %{conn: conn} do
      AgentRegistry.register_agent("a1", %{name: "Agent1"})
      AgentRegistry.register_agent("a2", %{name: "Agent2"})

      conn = get(conn, ~p"/api/v2/agents")
      body = json_response(conn, 200)

      assert body["meta"]["total"] == 2
      assert length(body["data"]) == 2
    end

    test "cursor pagination works", %{conn: conn} do
      # Register enough agents to test pagination
      for i <- 1..5 do
        AgentRegistry.register_agent("agent-#{i}", %{name: "Agent #{i}"})
        Process.sleep(1)
      end

      # First page with limit 2
      conn1 = get(conn, ~p"/api/v2/agents?limit=2")
      body1 = json_response(conn1, 200)

      assert length(body1["data"]) == 2
      assert body1["meta"]["has_more"] == true
      assert body1["meta"]["cursor"] != nil

      # Next page via cursor
      cursor = body1["meta"]["cursor"]
      conn2 = get(conn, "/api/v2/agents?cursor=#{cursor}&limit=2")
      body2 = json_response(conn2, 200)

      assert length(body2["data"]) == 2
      assert body2["meta"]["has_more"] == true

      # Ensure no overlap between pages
      ids1 = Enum.map(body1["data"], & &1["id"])
      ids2 = Enum.map(body2["data"], & &1["id"])
      assert MapSet.disjoint?(MapSet.new(ids1), MapSet.new(ids2))
    end
  end

  describe "GET /api/v2/agents/:id" do
    test "returns single agent with health score", %{conn: conn} do
      AgentRegistry.register_agent("test-agent", %{name: "Test"})

      conn = get(conn, ~p"/api/v2/agents/test-agent")
      body = json_response(conn, 200)

      assert body["data"]["id"] == "test-agent"
      assert is_number(body["data"]["health_score"])
      assert is_list(body["data"]["recent_metrics"])
    end

    test "returns 404 envelope for missing agent", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/agents/nonexistent")
      body = json_response(conn, 404)

      assert body["error"]["code"] == "not_found"
      assert body["error"]["message"] == "Agent not found"
    end
  end

  # ========== Sessions ==========

  describe "GET /api/v2/sessions" do
    test "returns envelope with sessions", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/sessions")
      body = json_response(conn, 200)

      assert is_list(body["data"])
      assert body["meta"]["total"] == 0
    end
  end

  # ========== Metrics ==========

  describe "GET /api/v2/metrics" do
    test "returns fleet metrics envelope", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/metrics")
      body = json_response(conn, 200)

      assert is_map(body["data"])
      assert is_map(body["meta"])
    end
  end

  describe "GET /api/v2/metrics/:agent_id" do
    test "returns per-agent metrics", %{conn: conn} do
      MetricsCollector.record("test-agent", :error_count, 1)
      Process.sleep(10)

      conn = get(conn, ~p"/api/v2/metrics/test-agent")
      body = json_response(conn, 200)

      assert is_list(body["data"])
    end
  end

  # ========== SLOs ==========

  describe "GET /api/v2/slos" do
    test "returns all SLIs with error budgets", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/slos")
      body = json_response(conn, 200)

      assert is_list(body["data"])
      assert body["meta"]["total"] == 5

      first = hd(body["data"])
      assert Map.has_key?(first, "name")
      assert Map.has_key?(first, "target")
      assert Map.has_key?(first, "error_budget")
    end
  end

  describe "GET /api/v2/slos/:name" do
    test "returns single SLI with history", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/slos/agent_availability")
      body = json_response(conn, 200)

      assert body["data"]["name"] == "agent_availability"
      assert Map.has_key?(body["data"], "history")
      assert Map.has_key?(body["data"], "error_budget")
    end

    test "returns 404 for unknown SLI", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/slos/nonexistent_sli_xyz")
      body = json_response(conn, 404)

      assert body["error"]["code"] == "not_found"
    end
  end

  # ========== Alerts ==========

  describe "GET /api/v2/alerts" do
    test "returns alert history envelope", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/alerts")
      body = json_response(conn, 200)

      assert is_list(body["data"])
      assert is_map(body["meta"])
    end
  end

  describe "GET /api/v2/alerts/rules" do
    test "returns bootstrap rules", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/alerts/rules")
      body = json_response(conn, 200)

      assert is_list(body["data"])
      # 3 bootstrap rules
      assert body["meta"]["total"] == 3
    end
  end

  describe "POST /api/v2/alerts/rules" do
    test "creates a new alert rule", %{conn: conn} do
      payload = %{
        "name" => "Test Rule",
        "metric" => "test_metric",
        "scope" => "fleet",
        "threshold" => 42,
        "comparator" => "gt",
        "severity" => "warning"
      }

      conn = post(conn, ~p"/api/v2/alerts/rules", payload)
      body = json_response(conn, 201)

      assert body["data"]["id"]
      assert body["meta"]["created"] == true

      # Verify rule was created
      rules = AlertRulesEngine.list_rules()
      assert Enum.any?(rules, &(&1.name == "Test Rule"))
    end
  end

  # ========== Audit ==========

  describe "GET /api/v2/audit" do
    test "returns audit log envelope", %{conn: conn} do
      AuditLog.log_sync("test_event", "test_actor", "test_resource", %{foo: "bar"})

      conn = get(conn, ~p"/api/v2/audit")
      body = json_response(conn, 200)

      assert is_list(body["data"])
      assert body["meta"]["total"] >= 1
    end

    test "filters by event_type", %{conn: conn} do
      AuditLog.log_sync("type_a", "actor1", "res1", %{})
      AuditLog.log_sync("type_b", "actor2", "res2", %{})

      conn = get(conn, ~p"/api/v2/audit?event_type=type_a")
      body = json_response(conn, 200)

      assert Enum.all?(body["data"], &(&1["event_type"] == "type_a"))
    end
  end

  # ========== OpenAPI ==========

  describe "GET /api/v2/openapi.json" do
    test "returns valid JSON with paths", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/openapi.json")
      body = json_response(conn, 200)

      assert body["openapi"] == "3.0.3"
      assert is_map(body["paths"])
      assert Map.has_key?(body["paths"], "/api/v2/agents")
      assert Map.has_key?(body["paths"], "/api/v2/slos")
      assert Map.has_key?(body["paths"], "/api/v2/alerts")
      assert Map.has_key?(body["info"], "title")
    end
  end
end
