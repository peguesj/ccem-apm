defmodule ApmV5Web.ConversationDrawerTest do
  @moduledoc """
  Tests for the ConversationDrawer component and its integration with
  ConversationMonitorLive — covering toggle events, tab switching,
  resize event handling, keyboard-shortcut events, and ARIA attributes.
  """

  use ApmV5Web.ConnCase, async: true
  import Phoenix.LiveViewTest

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Ensure the mock stubs are available in the test process.
  setup do
    :ok
  end

  # ---------------------------------------------------------------------------
  # Drawer toggle
  # ---------------------------------------------------------------------------

  describe "toggle_tray event" do
    test "opens the drawer when it is closed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/conversations")

      # Drawer starts collapsed — the h-14 class must be present.
      assert has_element?(view, "[data-drawer-state='collapsed']")

      view |> element("[phx-click='toggle_tray']") |> render_click()

      assert has_element?(view, "[data-drawer-state='expanded']")
    end

    test "closes the drawer when it is open", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/conversations")

      # Open first
      view |> element("[phx-click='toggle_tray']") |> render_click()
      assert has_element?(view, "[data-drawer-state='expanded']")

      # Close
      view |> element("[phx-click='toggle_tray']") |> render_click()
      assert has_element?(view, "[data-drawer-state='collapsed']")
    end
  end

  # ---------------------------------------------------------------------------
  # Tab switching
  # ---------------------------------------------------------------------------

  describe "select_tray_tab event" do
    test "switches to the selected tab and opens the drawer", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/conversations")

      view
      |> element("[phx-click='select_tray_tab'][phx-value-tab='log']")
      |> render_click()

      assert has_element?(view, "[data-drawer-state='expanded']")
      assert has_element?(view, "[aria-selected='true'][data-tab='log']")
    end

    test "active tab button has aria-selected=true", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/conversations")

      view
      |> element("[phx-click='select_tray_tab'][phx-value-tab='actions']")
      |> render_click()

      assert has_element?(view, "[aria-selected='true'][data-tab='actions']")
      refute has_element?(view, "[aria-selected='true'][data-tab='live']")
    end

    test "inactive tab buttons have aria-selected=false", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/conversations")

      # Default active tab is "live"; log should be false
      assert has_element?(view, "[aria-selected='false'][data-tab='log']")
    end
  end

  # ---------------------------------------------------------------------------
  # drawer_resized event
  # ---------------------------------------------------------------------------

  describe "drawer_resized event" do
    test "updates drawer_height assign within bounds", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/conversations")

      view
      |> element("[data-drawer-root]")
      |> render_hook("drawer_resized", %{"height" => 400})

      # The inline style should reflect the new height.
      html = render(view)
      assert html =~ "400px"
    end

    test "clamps height to minimum 56px", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/conversations")

      view
      |> element("[data-drawer-root]")
      |> render_hook("drawer_resized", %{"height" => 10})

      html = render(view)
      assert html =~ "56px"
    end

    test "clamps height to maximum expressed in assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/conversations")

      view
      |> element("[data-drawer-root]")
      |> render_hook("drawer_resized", %{"height" => 99_999})

      html = render(view)
      # Max cap is 90vh — rendered as a CSS value, so we just verify an
      # excessively large px value is NOT echoed verbatim.
      refute html =~ "99999px"
    end
  end

  # ---------------------------------------------------------------------------
  # Keyboard shortcut event handlers
  # ---------------------------------------------------------------------------

  describe "keyboard shortcut events" do
    test "drawer_collapse event collapses the drawer", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/conversations")

      # Open first
      view |> element("[phx-click='toggle_tray']") |> render_click()
      assert has_element?(view, "[data-drawer-state='expanded']")

      view
      |> element("[data-drawer-root]")
      |> render_hook("drawer_collapse", %{})

      assert has_element?(view, "[data-drawer-state='collapsed']")
    end

    test "drawer_toggle event toggles the drawer", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/conversations")

      assert has_element?(view, "[data-drawer-state='collapsed']")

      view
      |> element("[data-drawer-root]")
      |> render_hook("drawer_toggle", %{})

      assert has_element?(view, "[data-drawer-state='expanded']")
    end

    test "drawer_fullscreen event sets height to fullscreen state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/conversations")

      view
      |> element("[data-drawer-root]")
      |> render_hook("drawer_fullscreen", %{})

      html = render(view)
      # Fullscreen height class or style must be applied
      assert html =~ "fullscreen" or html =~ "calc(100vh - 48px)"
    end
  end

  # ---------------------------------------------------------------------------
  # ARIA attributes
  # ---------------------------------------------------------------------------

  describe "ARIA attributes" do
    test "tab panel has role=tabpanel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/conversations")

      # Open the drawer to render the tab panel
      view |> element("[phx-click='toggle_tray']") |> render_click()

      assert has_element?(view, "[role='tabpanel']")
    end

    test "tab buttons have role=tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/conversations")

      assert has_element?(view, "[role='tab']")
    end

    test "drawer handle button has aria-label", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/conversations")

      assert has_element?(view, "[aria-label='Conversation Inspector']")
    end

    test "aria-controls on tab buttons references panel id", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/conversations")

      assert has_element?(view, "[role='tab'][aria-controls='conversation-drawer-panel']")
    end
  end
end
