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

  test "dashboard shows dependency graph placeholder", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Dependency Graph"
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
