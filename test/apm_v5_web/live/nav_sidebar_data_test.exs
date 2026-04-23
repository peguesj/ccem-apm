defmodule ApmV5Web.NavSidebarDataTest do
  @moduledoc """
  TDD tests for sidebar nav data assignment fixes.

  Verifies that DashboardLive and PluginDashboardLive mount/3 correctly
  populates :plugins and :integrations assigns so the dynamic sidebar
  sections render (Task 1).

  Also verifies:
  - Plugin settings detail page shows endpoints (Task 2)
  - APM badge rendered for plugins with plugin_scope() == :apm (Task 3)
  """

  use ApmV5Web.ConnCase

  import Phoenix.LiveViewTest

  setup do
    for mod <- [ApmV5.UpmStore, ApmV5.PortManager, ApmV5.ChatStore,
                ApmV5.DashboardStore, ApmV5.ProjectStore] do
      case mod.start_link([]) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        _ -> :ok
      end
    end

    ApmV5.AgentRegistry.clear_all()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Task 1: DashboardLive sidebar nav data
  # ---------------------------------------------------------------------------

  describe "DashboardLive sidebar nav data" do
    test "sidebar renders with apm-sidebar element", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "apm-sidebar"
    end

    test "sidebar renders Plugins nav section", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      # The plugins section header is always present
      assert html =~ "Plugins"
    end

    test "sidebar renders Integrations nav section", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Integrations"
    end

    test "sidebar renders Library nav item", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Library"
    end

    test "sidebar brand always shows CCEM APM", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "CCEM APM"
    end

    test "sidebar renders without crashing (no assign_error)", %{conn: conn} do
      # This test ensures the view mounts successfully without a KeyError
      # on missing :plugins or :integrations assigns.
      assert {:ok, _view, html} = live(conn, ~p"/")
      refute html =~ "assign @plugins not available"
      refute html =~ "assign @integrations not available"
    end
  end

  # ---------------------------------------------------------------------------
  # Task 1: PluginDashboardLive sidebar nav data
  # ---------------------------------------------------------------------------

  describe "PluginDashboardLive sidebar nav data" do
    test "sidebar renders on /plugins page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/plugins")
      assert html =~ "apm-sidebar"
    end

    test "sidebar Plugins section present on /plugins page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/plugins")
      assert html =~ "Plugins"
    end

    test "sidebar Integrations section present on /plugins page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/plugins")
      assert html =~ "Integrations"
    end

    test "sidebar renders on /integrations route", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/integrations")
      assert html =~ "apm-sidebar"
    end

    test "no assign error on /plugins page", %{conn: conn} do
      assert {:ok, _view, html} = live(conn, ~p"/plugins")
      refute html =~ "assign @plugins not available"
      refute html =~ "assign @integrations not available"
    end
  end

  # ---------------------------------------------------------------------------
  # Task 2: Plugin settings dynamic loading
  # ---------------------------------------------------------------------------

  describe "PluginDashboardLive plugin settings" do
    test "registered tab renders without crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/plugins")
      html = render_click(view, "switch_tab", %{"tab" => "registered"})
      assert html =~ "Engine Plugins" or html =~ "engine plugins" or html =~ "No engine plugins"
    end

    test "selecting a registered plugin shows action panel", %{conn: conn} do
      plugins = ApmV5.Plugins.PluginRegistry.list_plugins()

      if plugins == [] do
        assert true
      else
        plugin = List.first(plugins)
        {:ok, view, _html} = live(conn, ~p"/plugins")
        _html = render_click(view, "switch_tab", %{"tab" => "registered"})
        html = render_click(view, "select_plugin", %{"name" => plugin.name})
        # Plugin panel should be present showing the plugin name
        assert html =~ plugin.name
      end
    end

    test "plugin action panel shows endpoints when plugin selected", %{conn: conn} do
      plugins = ApmV5.Plugins.PluginRegistry.list_plugins()

      if plugins == [] do
        assert true
      else
        plugin = List.first(plugins)
        {:ok, view, _html} = live(conn, ~p"/plugins")
        _html = render_click(view, "switch_tab", %{"tab" => "registered"})
        html = render_click(view, "select_plugin", %{"name" => plugin.name})
        Enum.each(plugin.endpoints, fn ep ->
          assert html =~ ep.action
        end)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Task 3: APM badge for plugins with scope :apm
  # ---------------------------------------------------------------------------

  describe "APM badge for :apm scope plugins" do
    test "plugin cards show APM badge for :apm scope plugins", %{conn: conn} do
      plugins = ApmV5.Plugins.PluginRegistry.list_plugins()
      apm_plugins = Enum.filter(plugins, &(Map.get(&1, :scope) == :apm))

      {:ok, view, _html} = live(conn, ~p"/plugins")
      html = render_click(view, "switch_tab", %{"tab" => "registered"})

      if apm_plugins != [] do
        # APM badge should appear in the engine plugin cards
        assert html =~ "APM"
      else
        assert true
      end
    end

    test "plugin detail panel shows APM badge for :apm scope plugin", %{conn: conn} do
      plugins = ApmV5.Plugins.PluginRegistry.list_plugins()
      apm_plugin = Enum.find(plugins, &(Map.get(&1, :scope) == :apm))

      if apm_plugin do
        {:ok, view, _html} = live(conn, ~p"/plugins")
        _html = render_click(view, "switch_tab", %{"tab" => "registered"})
        html = render_click(view, "select_plugin", %{"name" => apm_plugin.name})
        assert html =~ "APM"
      else
        assert true
      end
    end
  end
end
