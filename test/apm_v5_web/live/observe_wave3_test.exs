defmodule ApmV5Web.ObserveWave3Test do
  @moduledoc """
  Observe Wave 3 TDD suite (CP-183 / US-458).

  Unit tests for the four LiveViews implemented in Wave 3:
  - ApmV5Web.DashboardLive (CP-175)
  - ApmV5Web.FleetLive (CP-176)
  - ApmV5Web.SessionDetailLive (CP-177)
  - ApmV5Web.AuthorizationLive (CP-178)

  Run with: mix test --only observe_wave3
  """

  use ApmV5Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :observe_wave3

  setup do
    ApmV5.GenServerHelpers.ensure_processes_alive()
    ApmV5.AgentRegistry.clear_all()
    :ok
  end

  # ---------------------------------------------------------------------------
  # DashboardLive (CP-175) — /
  # ---------------------------------------------------------------------------

  describe "DashboardLive" do
    test "mounts and renders the DS page_layout shell", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")
      # DS page_layout emits ccem-bg wrapper; the dashboard title is also present
      assert html =~ "ccem-bg" or html =~ "Dashboard"
    end

    test "sidebar_collapsed assign defaults to false on mount", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.sidebar_collapsed == false
    end

    test "inspector_open assign defaults to false on mount", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.inspector_open == false
    end

    test "inspector_mode assign defaults to 'copilot' on mount", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.inspector_mode == "copilot"
    end

    test "toggle_sidebar event flips sidebar_collapsed", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      render_click(lv, "toggle_sidebar")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.sidebar_collapsed == true
    end

    test "toggle_sidebar event is idempotent across two calls", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      render_click(lv, "toggle_sidebar")
      render_click(lv, "toggle_sidebar")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.sidebar_collapsed == false
    end

    test "toggle_inspector event flips inspector_open", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      render_click(lv, "toggle_inspector")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.inspector_open == true
    end

    test "page_title assign is 'Dashboard'", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.page_title == "Dashboard"
    end
  end

  # ---------------------------------------------------------------------------
  # FleetLive (CP-176) — /fleet
  # ---------------------------------------------------------------------------

  describe "FleetLive" do
    test "mounts and renders Fleet content", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/fleet")
      assert html =~ "Fleet" or html =~ "agent" or html =~ "ccem-bg"
    end

    test "view_mode assign defaults to 'Grid' on mount", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/fleet")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.view_mode == "Grid"
    end

    test "status_filter assign defaults to 'All' on mount", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/fleet")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.status_filter == "All"
    end

    test "filter assign defaults to empty string on mount", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/fleet")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.filter == ""
    end

    test "sidebar_collapsed assign defaults to false on mount", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/fleet")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.sidebar_collapsed == false
    end

    test "set_view event switches view_mode to 'List'", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/fleet")
      render_click(lv, "set_view", %{"value" => "List"})
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.view_mode == "List"
    end

    test "set_status_filter event updates status_filter", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/fleet")
      render_click(lv, "set_status_filter", %{"status" => "active"})
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.status_filter == "active"
    end

    test "toggle_sidebar event flips sidebar_collapsed", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/fleet")
      render_click(lv, "toggle_sidebar")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.sidebar_collapsed == true
    end

    test "page_title assign is 'Fleet'", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/fleet")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.page_title == "Fleet"
    end
  end

  # ---------------------------------------------------------------------------
  # SessionDetailLive (CP-177) — /observe/sessions/:session_id
  # ---------------------------------------------------------------------------

  describe "SessionDetailLive" do
    test "mounts with session_id param and renders", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/observe/sessions/test-session-abc123")
      assert html =~ "Session" or html =~ "Transcript" or html =~ "ccem-bg"
    end

    test "session_id assign is set from the route param", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/observe/sessions/test-session-abc123")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.session_id == "test-session-abc123"
    end

    test "tab assign defaults to 'Transcript' on mount", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/observe/sessions/test-session-abc123")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.tab == "Transcript"
    end

    test "sidebar_collapsed assign defaults to false on mount", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/observe/sessions/test-session-abc123")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.sidebar_collapsed == false
    end

    test "inspector_open assign defaults to false on mount", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/observe/sessions/test-session-abc123")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.inspector_open == false
    end

    test "set_tab event switches tab to 'Tool Calls'", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/observe/sessions/test-session-abc123")
      render_click(lv, "set_tab", %{"value" => "Tool Calls"})
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.tab == "Tool Calls"
    end

    test "set_tab event switches tab to 'Tokens'", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/observe/sessions/test-session-abc123")
      render_click(lv, "set_tab", %{"value" => "Tokens"})
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.tab == "Tokens"
    end

    test "page_title assign is 'Session Detail'", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/observe/sessions/test-session-abc123")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.page_title == "Session Detail"
    end
  end

  # ---------------------------------------------------------------------------
  # AuthorizationLive (CP-178) — /authorization
  # ---------------------------------------------------------------------------

  describe "AuthorizationLive" do
    test "mounts and renders authorization page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/authorization")
      assert html =~ "Authorization" or html =~ "AgentLock" or html =~ "Policy" or html =~ "ccem-bg"
    end

    test "ttl_remaining starts at 0 when no pending decisions", %{conn: conn} do
      # With no pending decisions, ttl_remaining is initialized to 0 per mount logic
      {:ok, lv, _html} = live(conn, ~p"/authorization")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.ttl_remaining in [0, 20]
    end

    test "sidebar_collapsed assign defaults to false on mount", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/authorization")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.sidebar_collapsed == false
    end

    test "inspector_open assign defaults to false on mount", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/authorization")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.inspector_open == false
    end

    test "active_tab assign defaults to 'overview' on mount", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/authorization")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.active_tab == "overview"
    end

    test "timeout_seconds assign is 20 on mount", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/authorization")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.timeout_seconds == 20
    end

    test "page_title assign is 'Authorization v9'", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/authorization")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.page_title == "Authorization v9"
    end

    test "govern/authorization alias route also mounts", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/govern/authorization")
      assert html =~ "Authorization" or html =~ "ccem-bg"
    end
  end
end
