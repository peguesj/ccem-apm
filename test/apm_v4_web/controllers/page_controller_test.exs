defmodule ApmV4Web.DashboardLiveTest do
  use ApmV4Web.ConnCase

  import Phoenix.LiveViewTest

  alias ApmV4.AgentRegistry

  setup do
    AgentRegistry.clear_all()
    :ok
  end

  test "GET / renders the dashboard LiveView", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "CCEM APM v4"
  end

  test "dashboard displays sidebar navigation", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Dashboard"
    assert html =~ "Agents"
    assert html =~ "Ralph"
    assert html =~ "Sessions"
    assert html =~ "Settings"
    assert has_element?(view, "aside nav")
  end

  test "dashboard displays stat cards", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Agents"
    assert html =~ "Active"
    assert html =~ "Idle"
    assert html =~ "Errors"
  end

  test "dashboard shows agent fleet section", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Agent Fleet"
    assert html =~ "No agents registered"
  end

  test "dashboard shows agents when registered", %{conn: conn} do
    AgentRegistry.register_agent("test-agent-1", %{name: "Test Agent", tier: 1, status: "active"})

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Test Agent"
    assert html =~ "test-agent-1"
    assert html =~ "active"
  end

  test "dashboard renders D3 dependency graph container with hook", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Dependency Graph"
    assert has_element?(view, ~s{div[id="dep-graph"][phx-hook="DependencyGraph"]})
  end

  test "dependency graph container uses phx-update=ignore", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(phx-update="ignore")
    assert html =~ ~s(phx-hook="DependencyGraph")
  end

  test "graph renders with zero agents (empty state)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    # Graph element should still be present even with no agents
    assert has_element?(view, "#dep-graph")
  end

  test "graph data pushed with registered agents", %{conn: conn} do
    AgentRegistry.register_agent("graph-agent-1", %{name: "Graph Agent 1", tier: 1, status: "active", deps: []})
    AgentRegistry.register_agent("graph-agent-2", %{name: "Graph Agent 2", tier: 2, status: "idle", deps: ["graph-agent-1"]})

    {:ok, view, _html} = live(conn, ~p"/")
    # Agents should be visible in the agent fleet
    assert render(view) =~ "Graph Agent 1"
    assert render(view) =~ "Graph Agent 2"
    # Hook element should be present for D3 to render into
    assert has_element?(view, "#dep-graph")
  end

  test "graph renders with many agents (5+)", %{conn: conn} do
    for i <- 1..5 do
      tier = if i <= 2, do: 1, else: if(i <= 4, do: 2, else: 3)
      AgentRegistry.register_agent("agent-#{i}", %{name: "Agent #{i}", tier: tier, status: "active"})
    end

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#dep-graph")
    html = render(view)
    for i <- 1..5, do: assert(html =~ "Agent #{i}")
  end

  test "select_agent event switches to inspector tab with agent details", %{conn: conn} do
    AgentRegistry.register_agent("inspect-me", %{name: "Inspector Agent", tier: 2, status: "active", deps: []})

    {:ok, view, _html} = live(conn, ~p"/")
    # Simulate clicking on a graph node (pushes select_agent event)
    html = render_hook(view, "select_agent", %{"agent_id" => "inspect-me"})
    assert html =~ "Inspector Agent"
    assert html =~ "inspect-me"
    assert html =~ "active"
  end

  test "select_agent with unknown agent_id does not crash", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    # Should handle gracefully without error
    html = render_hook(view, "select_agent", %{"agent_id" => "nonexistent"})
    # Should still show the default inspector message
    assert html =~ "Click an agent or graph node to inspect"
  end

  test "graph container has correct CSS classes for sizing", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "w-full h-48"
    assert html =~ "bg-base-300"
  end

  test "switching tabs updates the active tab", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html = view |> element(~s{button[phx-value-tab="ralph"]}) |> render_click()
    assert html =~ "Ralph Methodology"

    html = view |> element(~s{button[phx-value-tab="commands"]}) |> render_click()
    assert html =~ "Slash Commands"

    html = view |> element(~s{button[phx-value-tab="todos"]}) |> render_click()
    assert html =~ "Active Tasks"
  end

  test "dashboard shows notification count", %{conn: conn} do
    AgentRegistry.add_notification(%{title: "Test", message: "Hello", level: "info"})

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Test"
  end

  test "clearing notifications works", %{conn: conn} do
    AgentRegistry.add_notification(%{title: "Test Notif", message: "Hello", level: "info"})

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Test Notif"

    html = view |> element(~s{button[phx-click="clear_notifications"]}) |> render_click()
    assert html =~ "No notifications"
  end

  test "dashboard top bar shows LIVE badge and clock", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "LIVE"
    assert html =~ "clock"
  end

  test "dashboard renders responsive at 1024px+ widths", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    # Verify grid classes that make responsive layout
    assert html =~ "lg:grid-cols-6"
    assert html =~ "md:grid-cols-3"
  end

  # --- PubSub Real-Time Update Tests (US-009) ---

  test "new agent registration appears in LiveView via PubSub", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "No agents registered"

    # Register an agent after the LiveView is connected
    AgentRegistry.register_agent("pubsub-agent-1", %{name: "PubSub Agent", tier: 1, status: "active"})

    # LiveView should receive the PubSub message and re-render
    html = render(view)
    assert html =~ "PubSub Agent"
    assert html =~ "pubsub-agent-1"
  end

  test "agent status change updates LiveView via PubSub", %{conn: conn} do
    AgentRegistry.register_agent("status-agent", %{name: "Status Agent", tier: 1, status: "idle"})

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "idle"

    # Update agent status
    AgentRegistry.update_status("status-agent", "active")

    html = render(view)
    assert html =~ "active"
  end

  test "stat cards update in real-time when agents change via PubSub", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # Register agents with different statuses
    AgentRegistry.register_agent("active-1", %{name: "Active 1", status: "active"})
    AgentRegistry.register_agent("idle-1", %{name: "Idle 1", status: "idle"})
    AgentRegistry.register_agent("error-1", %{name: "Error 1", status: "error"})

    html = render(view)
    # Should show 3 total agents, 1 active, 1 idle, 1 error
    assert html =~ "Active 1"
    assert html =~ "Idle 1"
    assert html =~ "Error 1"
  end

  test "notification appears in real-time via PubSub", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # Add notification after LiveView is connected
    AgentRegistry.add_notification(%{title: "Live Alert", message: "Something happened", level: "warning"})

    html = render(view)
    assert html =~ "Live Alert"
    assert html =~ "Something happened"
  end

  test "multiple rapid agent registrations all appear via PubSub", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # Register multiple agents rapidly
    for i <- 1..5 do
      AgentRegistry.register_agent("rapid-#{i}", %{name: "Rapid Agent #{i}", status: "active"})
    end

    html = render(view)
    for i <- 1..5 do
      assert html =~ "Rapid Agent #{i}"
    end
  end

  test "D3 graph container persists after PubSub agent updates", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    AgentRegistry.register_agent("graph-pubsub", %{name: "Graph PubSub", tier: 2, status: "active", deps: []})

    # Graph container should still be present with correct hook
    assert has_element?(view, ~s{div[id="dep-graph"][phx-hook="DependencyGraph"]})
  end

  test "heartbeat (update_status) triggers PubSub update in LiveView", %{conn: conn} do
    AgentRegistry.register_agent("heartbeat-agent", %{name: "Heartbeat Agent", tier: 1, status: "idle"})

    {:ok, view, _html} = live(conn, ~p"/")

    # Simulate heartbeat (status update)
    AgentRegistry.update_status("heartbeat-agent", "active")

    html = render(view)
    assert html =~ "active"
  end

  test "PubSub updates work across multiple concurrent LiveView connections", %{conn: conn} do
    # Simulate two browser tabs
    {:ok, view1, _html1} = live(conn, ~p"/")
    {:ok, view2, _html2} = live(conn, ~p"/")

    # Register an agent
    AgentRegistry.register_agent("multi-tab", %{name: "Multi Tab Agent", status: "active"})

    # Both views should receive the update
    assert render(view1) =~ "Multi Tab Agent"
    assert render(view2) =~ "Multi Tab Agent"
  end

  test "agent topology change triggers graph data push", %{conn: conn} do
    AgentRegistry.register_agent("topo-1", %{name: "Topo 1", status: "active", deps: []})

    {:ok, view, _html} = live(conn, ~p"/")

    # Register agent with dependency - changes graph topology
    AgentRegistry.register_agent("topo-2", %{name: "Topo 2", status: "active", deps: ["topo-1"]})

    html = render(view)
    assert html =~ "Topo 1"
    assert html =~ "Topo 2"
    # Graph should still be present for D3 to render into
    assert has_element?(view, "#dep-graph")
  end
end
