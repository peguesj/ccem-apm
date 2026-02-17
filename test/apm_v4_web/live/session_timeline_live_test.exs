defmodule ApmV4Web.SessionTimelineLiveTest do
  use ApmV4Web.ConnCase

  import Phoenix.LiveViewTest

  alias ApmV4.AgentRegistry

  setup do
    AgentRegistry.clear_all()
    :ok
  end

  test "GET /timeline renders the session timeline page", %{conn: conn} do
    conn = get(conn, ~p"/timeline")
    assert html_response(conn, 200) =~ "Session Timeline"
  end

  test "timeline mounts as LiveView with timeline container", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/timeline")
    assert html =~ "Session Timeline"
    assert html =~ "session-timeline"
  end

  test "timeline container has WCAG attributes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/timeline")

    assert has_element?(
             view,
             ~s{div[id="session-timeline"][role="img"][aria-label="Session timeline gantt chart showing agent activity over time"]}
           )
  end

  test "timeline container has phx-hook attribute", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/timeline")
    assert has_element?(view, ~s{div[id="session-timeline"][phx-hook="SessionTimeline"]})
  end

  test "set_time_range event updates the time range", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/timeline")

    html = render_click(view, "set_time_range", %{"range" => "6h"})
    assert html =~ "last 6h"

    html = render_click(view, "set_time_range", %{"range" => "24h"})
    assert html =~ "last 24h"

    html = render_click(view, "set_time_range", %{"range" => "1h"})
    assert html =~ "last 1h"
  end

  test "select_session event filters to a session", %{conn: conn} do
    AgentRegistry.register_session(%{session_id: "test-sess-1", project: "myproject"})

    {:ok, view, html} = live(conn, ~p"/timeline")
    assert html =~ "all sessions"

    html = render_click(view, "select_session", %{"session_id" => "test-sess-1"})
    assert html =~ "test-sess-1"

    # Deselect
    html = render_click(view, "select_session", %{"session_id" => ""})
    assert html =~ "all sessions"
  end

  test "refresh event reloads data without error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/timeline")
    html = render_click(view, "refresh")
    assert html =~ "Session Timeline"
  end

  test "sidebar shows Timeline as active nav", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/timeline")
    assert html =~ "bg-primary/10 text-primary"
    assert html =~ "Timeline"
  end

  test "shows registered agents count", %{conn: conn} do
    AgentRegistry.register_agent("agent-1", %{name: "Test Agent"})
    {:ok, _view, html} = live(conn, ~p"/timeline")
    assert html =~ "1 agents"
  end

  test "shows no sessions message when empty", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/timeline")
    assert html =~ "No sessions registered"
  end

  test "time range buttons are rendered", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/timeline")
    assert html =~ "1h"
    assert html =~ "6h"
    assert html =~ "24h"
  end

  test "live_region for status is present", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/timeline")
    assert has_element?(view, ~s{div[id="timeline-status"][aria-live="polite"]})
  end
end
