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
end
