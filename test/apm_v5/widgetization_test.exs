defmodule ApmV5.WidgetizationTest do
  @moduledoc """
  Integration tests for the Dashboard Widgetization Engine (US-369).

  Run with: mix test --only widgetization
  """

  use ExUnit.Case, async: false

  @moduletag :widgetization

  alias ApmV5.WidgetConfigStore
  alias ApmV5.WidgetRegistry
  alias ApmV5.LayoutStore
  alias ApmV5.DashboardScopeEngine

  setup do
    # Ensure core GenServers are alive
    ApmV5.GenServerHelpers.ensure_processes_alive()
    :ok
  end

  # ── WidgetConfigStore ─────────────────────────────────────────────────────────

  describe "WidgetConfigStore" do
    test "put_config/get_config round-trip" do
      session_id = "test-sess-#{:erlang.unique_integer([:positive])}"
      config = %{show_sparkline: false, show_formations: true}

      :ok = WidgetConfigStore.put_config(session_id, "agent_fleet", config)
      result = WidgetConfigStore.get_config(session_id, "agent_fleet")

      assert result == config
    end

    test "get_config returns nil for unknown widget" do
      session_id = "test-sess-#{:erlang.unique_integer([:positive])}"
      assert WidgetConfigStore.get_config(session_id, "does_not_exist") == nil
    end

    test "get_all_configs returns all configs for a session" do
      session_id = "test-sess-#{:erlang.unique_integer([:positive])}"
      config_a = %{show_sparkline: false}
      config_b = %{max_items: 5}

      WidgetConfigStore.put_config(session_id, "agent_fleet", config_a)
      WidgetConfigStore.put_config(session_id, "notifications", config_b)

      all = WidgetConfigStore.get_all_configs(session_id)
      assert Map.get(all, "agent_fleet") == config_a
      assert Map.get(all, "notifications") == config_b
    end

    test "set_pinned/get_pinned round-trip" do
      session_id = "test-sess-#{:erlang.unique_integer([:positive])}"

      :ok = WidgetConfigStore.set_pinned(session_id, "projects")
      assert WidgetConfigStore.get_pinned(session_id) == "projects"
    end

    test "set_pinned with nil clears pinned widget" do
      session_id = "test-sess-#{:erlang.unique_integer([:positive])}"

      WidgetConfigStore.set_pinned(session_id, "projects")
      WidgetConfigStore.set_pinned(session_id, nil)

      assert WidgetConfigStore.get_pinned(session_id) == nil
    end

    test "clear_session removes all session state" do
      session_id = "test-sess-#{:erlang.unique_integer([:positive])}"

      WidgetConfigStore.put_config(session_id, "agent_fleet", %{foo: "bar"})
      WidgetConfigStore.set_pinned(session_id, "projects")

      :ok = WidgetConfigStore.clear_session(session_id)

      assert WidgetConfigStore.get_config(session_id, "agent_fleet") == nil
      assert WidgetConfigStore.get_pinned(session_id) == nil
    end

    test "set_pinned broadcasts on dashboard:scope PubSub" do
      session_id = "test-sess-#{:erlang.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "dashboard:scope:#{session_id}")

      WidgetConfigStore.set_pinned(session_id, "projects")

      assert_receive {:pinned_widget_changed, "projects"}, 500

      Phoenix.PubSub.unsubscribe(ApmV5.PubSub, "dashboard:scope:#{session_id}")
    end
  end

  # ── DashboardScopeEngine ──────────────────────────────────────────────────────

  describe "DashboardScopeEngine" do
    test "pin_scope_source broadcasts pinned_widget_changed" do
      session_id = "test-sess-#{:erlang.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "dashboard:scope:#{session_id}")

      :ok = DashboardScopeEngine.pin_scope_source(session_id, "projects")

      assert_receive {:pinned_widget_changed, "projects"}, 500

      Phoenix.PubSub.unsubscribe(ApmV5.PubSub, "dashboard:scope:#{session_id}")
    end

    test "broadcast_scope emits scope_changed on PubSub" do
      session_id = "test-sess-#{:erlang.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "dashboard:scope:#{session_id}")

      :ok = DashboardScopeEngine.broadcast_scope(session_id, :project, "ccem")

      assert_receive {:scope_changed, :project, "ccem"}, 500

      Phoenix.PubSub.unsubscribe(ApmV5.PubSub, "dashboard:scope:#{session_id}")
    end

    test "get_active_scope returns :global/nil by default" do
      session_id = "test-sess-#{:erlang.unique_integer([:positive])}"
      assert DashboardScopeEngine.get_active_scope(session_id) == {:global, nil}
    end

    test "get_active_scope returns set scope" do
      session_id = "test-sess-#{:erlang.unique_integer([:positive])}"
      DashboardScopeEngine.broadcast_scope(session_id, :project, "lcc")
      assert DashboardScopeEngine.get_active_scope(session_id) == {:project, "lcc"}
    end

    test "unpin resets scope to :global and broadcasts" do
      session_id = "test-sess-#{:erlang.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "dashboard:scope:#{session_id}")

      DashboardScopeEngine.pin_scope_source(session_id, "projects")
      DashboardScopeEngine.broadcast_scope(session_id, :project, "ccem")

      DashboardScopeEngine.unpin(session_id)

      assert_receive {:pinned_widget_changed, nil}, 500
      assert_receive {:scope_changed, :global, nil}, 500

      assert DashboardScopeEngine.get_active_scope(session_id) == {:global, nil}
      assert DashboardScopeEngine.get_pinned_widget(session_id) == nil

      Phoenix.PubSub.unsubscribe(ApmV5.PubSub, "dashboard:scope:#{session_id}")
    end

    test "clear_session removes all scope state" do
      session_id = "test-sess-#{:erlang.unique_integer([:positive])}"
      DashboardScopeEngine.pin_scope_source(session_id, "projects")
      DashboardScopeEngine.broadcast_scope(session_id, :project, "ccem")

      :ok = DashboardScopeEngine.clear_session(session_id)

      assert DashboardScopeEngine.get_active_scope(session_id) == {:global, nil}
      assert DashboardScopeEngine.get_pinned_widget(session_id) == nil
    end
  end

  # ── LayoutStore ───────────────────────────────────────────────────────────────

  describe "LayoutStore" do
    test "save_user_layout/get_user_layout round-trip" do
      session_id = "test-sess-#{:erlang.unique_integer([:positive])}"
      layout = %{preset_id: "custom", placements: [%{widget_id: "agent_fleet", col_start: 1, col_end: 5, row_start: 1, row_end: 3}]}

      :ok = LayoutStore.save_user_layout(session_id, layout)
      result = LayoutStore.get_user_layout(session_id)

      assert result.preset_id == "custom"
      assert length(result.placements) == 1
    end

    test "get_user_layout returns nil for unknown session" do
      session_id = "test-sess-#{:erlang.unique_integer([:positive])}"
      assert LayoutStore.get_user_layout(session_id) == nil
    end

    test "save_widget_config/get_widget_config round-trip" do
      session_id = "test-sess-#{:erlang.unique_integer([:positive])}"
      config = %{show_sparkline: false}

      :ok = LayoutStore.save_widget_config(session_id, "agent_fleet", config)
      result = LayoutStore.get_widget_config(session_id, "agent_fleet")

      assert result == config
    end

    test "get_widget_config returns nil for missing key" do
      session_id = "test-sess-#{:erlang.unique_integer([:positive])}"
      assert LayoutStore.get_widget_config(session_id, "not_here") == nil
    end

    test "set_pinned_widget/get_pinned_widget round-trip" do
      session_id = "test-sess-#{:erlang.unique_integer([:positive])}"

      :ok = LayoutStore.set_pinned_widget(session_id, "projects")
      assert LayoutStore.get_pinned_widget(session_id) == "projects"
    end

    test "set_pinned_widget with nil unpins" do
      session_id = "test-sess-#{:erlang.unique_integer([:positive])}"
      LayoutStore.set_pinned_widget(session_id, "projects")
      LayoutStore.set_pinned_widget(session_id, nil)
      assert LayoutStore.get_pinned_widget(session_id) == nil
    end

    test "list_presets returns at least the default preset" do
      presets = LayoutStore.list_presets()
      assert Enum.any?(presets, &(&1.id == "default"))
    end

    test "get_preset returns correct preset" do
      preset = LayoutStore.get_preset("default")
      assert preset != nil
      assert preset.id == "default"
      assert is_list(preset.placements)
      assert length(preset.placements) > 0
    end

    test "set_pinned_widget broadcasts :pinned_widget_changed" do
      session_id = "test-sess-#{:erlang.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "dashboard:session:#{session_id}")

      LayoutStore.set_pinned_widget(session_id, "projects")

      assert_receive {:pinned_widget_changed, "projects"}, 500

      Phoenix.PubSub.unsubscribe(ApmV5.PubSub, "dashboard:session:#{session_id}")
    end
  end

  # ── WidgetRegistry ────────────────────────────────────────────────────────────

  describe "WidgetRegistry" do
    test "list_widgets returns 13+ widgets including projects" do
      widgets = WidgetRegistry.list_widgets()
      assert length(widgets) >= 13

      widget_ids = Enum.map(widgets, & &1.id)
      assert "projects" in widget_ids
      assert "agent_fleet" in widget_ids
    end

    test "get_widget returns widget with new schema fields" do
      widget = WidgetRegistry.get_widget("agent_fleet")
      assert widget != nil
      assert widget.id == "agent_fleet"
      assert is_boolean(widget.editable)
      assert is_boolean(widget.pinnable)
      assert is_list(widget.supported_scopes)
      assert is_map(widget.default_config)
      assert is_integer(widget.display_order)
    end

    test "projects widget is pinnable" do
      widget = WidgetRegistry.get_widget("projects")
      assert widget != nil
      assert widget.pinnable == true
      assert "project" in widget.supported_scopes
    end

    test "register_widget adds plugin widget to ETS" do
      plugin_widget = %{
        id: "test_plugin_widget_#{:erlang.unique_integer([:positive])}",
        name: "Test Plugin Widget",
        description: "A test widget",
        category: :custom,
        source_module: ApmV5.AgentRegistry,
        refresh_interval: nil,
        min_width: 3,
        min_height: 2,
        config_schema: %{debug: "boolean"},
        default_config: %{debug: false},
        plugin: "test_plugin",
        version: "1.0.0",
        editable: true,
        pinnable: false,
        supported_scopes: ["global"],
        display_order: 99
      }

      :ok = WidgetRegistry.register_widget(plugin_widget)
      retrieved = WidgetRegistry.get_widget(plugin_widget.id)

      assert retrieved != nil
      assert retrieved.name == "Test Plugin Widget"
      assert retrieved.plugin == "test_plugin"
    end

    test "update_widget_config merges config into default_config" do
      :ok = WidgetRegistry.update_widget_config("agent_fleet", %{show_sparkline: false})
      widget = WidgetRegistry.get_widget("agent_fleet")
      assert widget.default_config.show_sparkline == false
    end

    test "resolve_config merges overrides over defaults" do
      widget = WidgetRegistry.get_widget("usage_summary")
      merged = WidgetRegistry.resolve_config("usage_summary", %{time_window: "7d"})

      assert Map.get(merged, :time_window) == "7d" || Map.get(merged, "time_window") == "7d"
    end

    test "list_pinnable returns widgets with pinnable=true" do
      pinnable = WidgetRegistry.list_pinnable()
      assert Enum.any?(pinnable, &(&1.id == "projects"))
      refute Enum.any?(pinnable, &(&1.id == "agent_fleet"))
    end

    test "list_by_scope filters by supported scope" do
      project_widgets = WidgetRegistry.list_by_scope("project")
      assert length(project_widgets) > 0
      assert Enum.all?(project_widgets, &("project" in &1.supported_scopes))
    end
  end
end
