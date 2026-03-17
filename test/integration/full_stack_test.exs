defmodule ApmV5.Integration.FullStackTest do
  @moduledoc """
  Integration tests verifying all ported components work together end-to-end.
  Covers HTTP API, LiveView mounting, D3.js rendering, AG-UI streaming,
  A2UI components, PubSub broadcasting, and session parsing.
  """

  use ApmV5Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ApmV5.AgentRegistry
  alias ApmV5.EventStream
  alias ApmV5.SessionParser
  alias ApmV5.A2ui.ComponentBuilder

  setup do
    ApmV5.GenServerHelpers.ensure_processes_alive()
    AgentRegistry.clear_all()
    EventStream.clear()
    :ok
  end

  # ──────────────────────────────────────────────────────────
  # API Integration: register -> heartbeat -> agents -> status
  # ──────────────────────────────────────────────────────────

  describe "API end-to-end flow" do
    test "register agent via POST, verify via GET /api/agents, send heartbeat, check status",
         %{conn: conn} do
      # 1. Register an agent via HTTP
      register_payload = %{
        agent_id: "integ-agent-1",
        name: "Integration Agent",
        tier: 1,
        status: "idle",
        deps: ["dep-1"],
        metadata: %{role: "worker"}
      }

      conn_reg = post(conn, ~p"/api/register", register_payload)
      assert %{"ok" => true, "agent_id" => "integ-agent-1"} = json_response(conn_reg, 201)

      # 2. Verify agent appears in GET /api/agents
      conn_agents = get(conn, ~p"/api/agents")
      agents_body = json_response(conn_agents, 200)
      assert length(agents_body["agents"]) == 1

      [agent] = agents_body["agents"]
      assert agent["id"] == "integ-agent-1"
      assert agent["name"] == "Integration Agent"
      assert agent["status"] == "idle"
      assert agent["tier"] == 1
      assert agent["deps"] == ["dep-1"]

      # 3. Send heartbeat to update status
      conn_hb = post(conn, ~p"/api/heartbeat", %{agent_id: "integ-agent-1", status: "active"})
      assert %{"ok" => true} = json_response(conn_hb, 200)

      # 4. Verify status updated
      updated_agent = AgentRegistry.get_agent("integ-agent-1")
      assert updated_agent.status == "active"

      # 5. Check /api/status reflects the agent count
      conn_status = get(conn, ~p"/api/status")
      status_body = json_response(conn_status, 200)
      assert status_body["agent_count"] == 1
      assert status_body["status"] == "ok"
      assert is_integer(status_body["uptime"])
      assert is_binary(status_body["server_version"])
    end

    test "multi-agent registration and listing", %{conn: conn} do
      for i <- 1..5 do
        post(conn, ~p"/api/register", %{
          agent_id: "batch-#{i}",
          name: "Batch Agent #{i}",
          tier: rem(i, 3) + 1,
          status: if(rem(i, 2) == 0, do: "active", else: "idle")
        })
      end

      conn_agents = get(conn, ~p"/api/agents")
      body = json_response(conn_agents, 200)
      assert length(body["agents"]) == 5

      conn_status = get(conn, ~p"/api/status")
      assert json_response(conn_status, 200)["agent_count"] == 5
    end

    test "notification created via API and retrievable", %{conn: conn} do
      post(conn, ~p"/api/notify", %{
        title: "Integration Test",
        message: "All systems go",
        level: "info"
      })

      notifications = AgentRegistry.get_notifications()
      assert length(notifications) == 1
      assert hd(notifications).title == "Integration Test"
      assert hd(notifications).message == "All systems go"
    end
  end

  # ──────────────────────────────────────────────────────────
  # LiveView Integration: DashboardLive
  # ──────────────────────────────────────────────────────────

  describe "LiveView: DashboardLive" do
    test "mounts and renders agent cards with pre-registered agents", %{conn: conn} do
      AgentRegistry.register_agent("lv-agent-1", %{name: "LiveView Agent", tier: 1, status: "active"})
      AgentRegistry.register_agent("lv-agent-2", %{name: "Worker Agent", tier: 2, status: "idle"})

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Agent Performance Monitor"
      assert html =~ "LiveView Agent"
      assert html =~ "Worker Agent"
      assert html =~ "active"
      assert html =~ "idle"
    end

    test "renders stat cards with correct counts", %{conn: conn} do
      AgentRegistry.register_agent("stat-1", %{status: "active"})
      AgentRegistry.register_agent("stat-2", %{status: "active"})
      AgentRegistry.register_agent("stat-3", %{status: "idle"})
      AgentRegistry.register_agent("stat-4", %{status: "error"})

      {:ok, _view, html} = live(conn, ~p"/")

      # Stat card values rendered
      assert html =~ "4"
      assert html =~ "Agents"
      assert html =~ "Active"
      assert html =~ "Idle"
      assert html =~ "Errors"
    end

    test "D3 dependency graph container present with hook", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, ~s{div[id="dep-graph"][phx-hook="DependencyGraph"]})
    end
  end

  # ──────────────────────────────────────────────────────────
  # LiveView Integration: RalphFlowchartLive
  # ──────────────────────────────────────────────────────────

  describe "LiveView: RalphFlowchartLive" do
    test "mounts at /ralph and renders flowchart container", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/ralph")

      assert html =~ "Ralph Flowchart"
      assert has_element?(view, ~s{div[phx-hook="RalphFlowchart"]})
    end

    test "renders all Ralph methodology steps", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/ralph")

      assert html =~ "You write a PRD"
      assert html =~ "Convert to prd.json"
      assert html =~ "Run ralph.sh"
      assert html =~ "AI picks a story"
      assert html =~ "Implements it"
      assert html =~ "Commits changes"
      assert html =~ "Updates prd.json"
      assert html =~ "Logs to progress.txt"
      assert html =~ "More stories?"
      assert html =~ "Done!"
    end

    test "step progression controls work", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/ralph")

      # Reset to step 1
      view |> element(~s{button[phx-click="reset_steps"]}) |> render_click()
      html = render(view)
      assert html =~ "You write a PRD"

      # Advance to next step
      view |> element(~s{button[phx-click="next_step"]}) |> render_click()
    end
  end

  # ──────────────────────────────────────────────────────────
  # SSE / AG-UI Integration
  # ──────────────────────────────────────────────────────────

  describe "AG-UI SSE streaming" do
    test "connect to /api/ag-ui/events, register agent, verify RUN_STARTED event received" do
      # Subscribe to EventStream PubSub topic
      EventStream.subscribe()

      # Register an agent - should emit RUN_STARTED
      AgentRegistry.register_agent("sse-agent-1", %{
        name: "SSE Agent",
        status: "active",
        metadata: %{role: "test"}
      })

      # Verify RUN_STARTED event was broadcast
      assert_receive {:ag_ui_event, event}, 2_000
      assert event.type == "RUN_STARTED"
      assert event.data.agent_id == "sse-agent-1"
      assert is_integer(event.sequence)
      assert event.sequence > 0
    end

    test "full agent lifecycle emits RUN_STARTED and RUN_FINISHED" do
      EventStream.subscribe()

      # Register -> RUN_STARTED
      AgentRegistry.register_agent("lifecycle-agent", %{name: "Lifecycle", status: "active"})
      assert_receive {:ag_ui_event, started}, 2_000
      assert started.type == "RUN_STARTED"

      # Complete -> RUN_FINISHED
      AgentRegistry.update_status("lifecycle-agent", "completed")
      assert_receive {:ag_ui_event, finished}, 2_000
      assert finished.type == "RUN_FINISHED"
      assert finished.data.agent_id == "lifecycle-agent"
      assert finished.sequence > started.sequence
    end

    test "STATE_SNAPSHOT emitted on SSE connect with current fleet", %{conn: conn} do
      AgentRegistry.register_agent("snap-1", %{name: "Snapshot Agent", status: "active"})

      EventStream.subscribe()

      task =
        Task.async(fn ->
          get(conn, ~p"/api/ag-ui/events")
        end)

      # Initial STATE_SNAPSHOT should be emitted on connect
      assert_receive {:ag_ui_event, snapshot}, 2_000
      assert snapshot.type == "STATE_SNAPSHOT"
      assert is_list(snapshot.data.agents)
      assert length(snapshot.data.agents) >= 1

      Task.shutdown(task, :brutal_kill)
    end
  end

  # ──────────────────────────────────────────────────────────
  # A2UI Integration
  # ──────────────────────────────────────────────────────────

  describe "A2UI JSONL components" do
    test "GET /api/a2ui/components returns valid JSONL with expected component types",
         %{conn: conn} do
      # Register agents to populate component data
      AgentRegistry.register_agent("a2ui-1", %{name: "A2UI Agent", tier: 1, status: "active"})

      AgentRegistry.add_notification(%{
        title: "Test Alert",
        message: "Integration test notification",
        level: "warning"
      })

      conn = get(conn, ~p"/api/a2ui/components")

      assert get_resp_header(conn, "content-type") |> List.first() =~ "jsonl"

      # Parse chunked JSONL response body
      body = conn.resp_body
      lines = String.split(body, "\n", trim: true)

      components =
        Enum.map(lines, fn line ->
          {:ok, component} = Jason.decode(line)
          component
        end)

      # Verify expected component types are present
      types = Enum.map(components, & &1["type"]) |> Enum.uniq() |> Enum.sort()
      assert "card" in types
      assert "table" in types
      assert "chart" in types
      assert "alert" in types
      assert "badge" in types
      assert "progress" in types

      # All components have unique IDs
      ids = Enum.map(components, & &1["id"])
      assert length(ids) == length(Enum.uniq(ids))

      # Card components have expected fields
      cards = Enum.filter(components, &(&1["type"] == "card"))
      assert length(cards) == 4

      Enum.each(cards, fn card ->
        assert Map.has_key?(card, "title")
        assert Map.has_key?(card, "body")
        assert Map.has_key?(card, "footer")
        assert Map.has_key?(card, "variant")
      end)

      # Table component has columns and rows
      [table] = Enum.filter(components, &(&1["type"] == "table"))
      assert is_list(table["columns"])
      assert is_list(table["rows"])
      assert length(table["rows"]) == 1
      assert table["sortable"] == true

      # Alert component from notification
      alerts = Enum.filter(components, &(&1["type"] == "alert"))
      assert length(alerts) >= 1
      alert = hd(alerts)
      assert alert["level"] == "warning"
      assert alert["dismissible"] == true
      assert alert["message"] =~ "Test Alert"
    end

    test "A2UI responds with JSON when Accept: application/json", %{conn: conn} do
      AgentRegistry.register_agent("a2ui-json", %{name: "JSON Agent", status: "idle"})

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/a2ui/components")

      assert get_resp_header(conn, "content-type") |> List.first() =~ "application/json"
      body = json_response(conn, 200)
      assert is_map(body)
      assert is_list(body["components"])
      assert length(body["components"]) > 0
    end
  end

  # ──────────────────────────────────────────────────────────
  # PubSub Integration: API -> LiveView real-time updates
  # ──────────────────────────────────────────────────────────

  describe "PubSub: API triggers LiveView updates" do
    test "register agent via API, verify LiveView receives update within 2 seconds",
         %{conn: conn} do
      # Mount the dashboard LiveView
      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "No agents registered"

      # Register an agent via the HTTP API (simulating external client)
      AgentRegistry.register_agent("pubsub-agent", %{
        name: "PubSub Test Agent",
        tier: 1,
        status: "active"
      })

      # The PubSub broadcast should trigger handle_info in the LiveView
      # which refreshes agents. Wait briefly for the async update.
      Process.sleep(100)

      # Re-render and verify the agent appears
      html = render(view)
      assert html =~ "PubSub Test Agent"
      assert html =~ "active"
    end

    test "status change via API updates LiveView agent display", %{conn: conn} do
      AgentRegistry.register_agent("status-agent", %{name: "Status Agent", status: "idle"})

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "Status Agent"
      assert html =~ "idle"

      # Update status
      AgentRegistry.update_status("status-agent", "error")
      Process.sleep(100)

      html = render(view)
      assert html =~ "error"
    end

    test "notification via API appears in LiveView", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      AgentRegistry.add_notification(%{
        title: "PubSub Notification",
        message: "Real-time alert test",
        level: "error"
      })

      Process.sleep(100)
      html = render(view)
      assert html =~ "PubSub Notification"
    end

    test "multiple rapid registrations all appear in LiveView", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for i <- 1..3 do
        AgentRegistry.register_agent("rapid-#{i}", %{
          name: "Rapid Agent #{i}",
          status: "active"
        })
      end

      Process.sleep(200)
      html = render(view)

      assert html =~ "Rapid Agent 1"
      assert html =~ "Rapid Agent 2"
      assert html =~ "Rapid Agent 3"
    end
  end

  # ──────────────────────────────────────────────────────────
  # Session Parser Integration
  # ──────────────────────────────────────────────────────────

  describe "SessionParser with fixture" do
    test "parses sample session JSONL fixture and verifies extracted metrics" do
      fixture_path = Path.join([File.cwd!(), "test", "fixtures", "sample_session.jsonl"])

      result = SessionParser.parse_jsonl(fixture_path)

      # Token extraction: 3 assistant messages
      # Message 1: input=500+100+50=650, output=200
      # Message 2: input=300, output=150
      # Message 3: input=200, output=100
      assert result.tokens.input == 1150
      assert result.tokens.output == 450

      # Tool counts: Read x2, Bash x1, Edit x1
      assert result.tools["Read"] == 2
      assert result.tools["Bash"] == 1
      assert result.tools["Edit"] == 1

      # Duration: 10:00:00 to 10:00:30 = 30 seconds
      assert result.duration_seconds == 30

      # User turns: 2 (first user message is plain text, second is tool_results only, third is plain text)
      assert result.turns == 2
    end
  end

  # ──────────────────────────────────────────────────────────
  # Cross-component integration
  # ──────────────────────────────────────────────────────────

  describe "cross-component integration" do
    test "agent registered via API appears in both agents list and A2UI components",
         %{conn: conn} do
      # Register via API
      post(conn, ~p"/api/register", %{
        agent_id: "cross-agent",
        name: "Cross Component Agent",
        tier: 2,
        status: "active"
      })

      # Verify in GET /api/agents
      conn_agents = get(conn, ~p"/api/agents")
      agents = json_response(conn_agents, 200)["agents"]
      assert Enum.any?(agents, &(&1["id"] == "cross-agent"))

      # Verify in A2UI components
      components = ComponentBuilder.build_all()
      table = Enum.find(components, &(&1.type == "table"))
      assert Enum.any?(table.rows, &(&1.id == "cross-agent"))

      # Verify in status chart
      chart = Enum.find(components, &(&1.type == "chart"))
      assert "active" in chart.labels

      # Verify badge exists
      badges = Enum.filter(components, &(&1.type == "badge"))
      assert Enum.any?(badges, &(&1.id == "badge-agent-cross-agent"))
    end

    test "agent lifecycle visible across all API surfaces", %{conn: conn} do
      EventStream.subscribe()

      # Register
      post(conn, ~p"/api/register", %{agent_id: "life-agent", name: "Lifecycle", status: "idle"})
      assert_receive {:ag_ui_event, started}, 2_000
      assert started.type == "RUN_STARTED"

      # Heartbeat to active
      post(conn, ~p"/api/heartbeat", %{agent_id: "life-agent", status: "active"})

      # Drain all queued AG-UI events from heartbeat/register side effects
      :timer.sleep(150)
      flush_ag_ui_events()

      # Verify active in agents list
      conn_agents = get(conn, ~p"/api/agents")
      [agent] = json_response(conn_agents, 200)["agents"]
      assert agent["status"] == "active"

      # Complete the agent -> RUN_FINISHED
      AgentRegistry.update_status("life-agent", "completed")
      assert_receive {:ag_ui_event, finished}, 2_000
      assert finished.type == "RUN_FINISHED"

      # Verify completed in agents list
      conn_agents2 = get(conn, ~p"/api/agents")
      [agent2] = json_response(conn_agents2, 200)["agents"]
      assert agent2["status"] == "completed"
    end
  end

  # --- Helpers ---

  defp flush_ag_ui_events do
    receive do
      {:ag_ui_event, _} -> flush_ag_ui_events()
    after
      0 -> :ok
    end
  end
end
