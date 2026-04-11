defmodule ApmV5.Plugins.Security.SecurityGuidancePluginTest do
  use ExUnit.Case, async: true

  alias ApmV5.Plugins.Security.SecurityGuidancePlugin

  # ---------------------------------------------------------------------------
  # PluginBehaviour contract
  # ---------------------------------------------------------------------------

  describe "PluginBehaviour contract" do
    test "plugin_name/0 returns expected machine-friendly name" do
      assert SecurityGuidancePlugin.plugin_name() == "security_guidance"
    end

    test "plugin_description/0 returns a non-empty string" do
      desc = SecurityGuidancePlugin.plugin_description()
      assert is_binary(desc) and byte_size(desc) > 0
    end

    test "plugin_version/0 returns a semver-like string" do
      version = SecurityGuidancePlugin.plugin_version()
      assert Regex.match?(~r/^\d+\.\d+\.\d+$/, version)
    end

    test "plugin_scope/0 returns :security" do
      assert SecurityGuidancePlugin.plugin_scope() == :security
    end

    test "default_enabled?/0 returns true" do
      assert SecurityGuidancePlugin.default_enabled?() == true
    end

    test "supervisor_children/0 returns empty list" do
      assert SecurityGuidancePlugin.supervisor_children() == []
    end

    test "plugin_live_module/0 returns nil (no LiveView yet)" do
      assert SecurityGuidancePlugin.plugin_live_module() == nil
    end

    test "plugin_integrations/0 returns empty list" do
      assert SecurityGuidancePlugin.plugin_integrations() == []
    end
  end

  # ---------------------------------------------------------------------------
  # list_endpoints/0
  # ---------------------------------------------------------------------------

  describe "list_endpoints/0" do
    test "returns a list of 4 endpoint descriptors" do
      endpoints = SecurityGuidancePlugin.list_endpoints()
      assert is_list(endpoints)
      assert length(endpoints) == 4
    end

    test "all endpoints have :action and :description keys" do
      for ep <- SecurityGuidancePlugin.list_endpoints() do
        assert is_binary(ep.action)
        assert is_binary(ep.description)
      end
    end

    test "expected actions are present" do
      actions = SecurityGuidancePlugin.list_endpoints() |> Enum.map(& &1.action)
      assert "hook_status" in actions
      assert "scan_history" in actions
      assert "covered_tools" in actions
      assert "pattern_summary" in actions
    end
  end

  # ---------------------------------------------------------------------------
  # handle_action/3 — covered_tools
  # ---------------------------------------------------------------------------

  describe "handle_action/3 — covered_tools" do
    test "returns :ok tuple with covered_tools list" do
      assert {:ok, result} = SecurityGuidancePlugin.handle_action("covered_tools", %{}, [])
      assert is_list(result.covered_tools)
    end

    test "covers exactly 8 tool types" do
      {:ok, result} = SecurityGuidancePlugin.handle_action("covered_tools", %{}, [])
      assert result.count == 8
    end

    test "covers Bash tool" do
      {:ok, result} = SecurityGuidancePlugin.handle_action("covered_tools", %{}, [])
      tools = Enum.map(result.covered_tools, & &1.tool)
      assert "Bash" in tools
    end

    test "covers WebFetch tool" do
      {:ok, result} = SecurityGuidancePlugin.handle_action("covered_tools", %{}, [])
      tools = Enum.map(result.covered_tools, & &1.tool)
      assert "WebFetch" in tools
    end

    test "covers Agent tool" do
      {:ok, result} = SecurityGuidancePlugin.handle_action("covered_tools", %{}, [])
      tools = Enum.map(result.covered_tools, & &1.tool)
      assert "Agent" in tools
    end

    test "covers Skill tool" do
      {:ok, result} = SecurityGuidancePlugin.handle_action("covered_tools", %{}, [])
      tools = Enum.map(result.covered_tools, & &1.tool)
      assert "Skill" in tools
    end

    test "covers Edit/Write/MultiEdit tools" do
      {:ok, result} = SecurityGuidancePlugin.handle_action("covered_tools", %{}, [])
      tools = Enum.map(result.covered_tools, & &1.tool)
      assert "Edit" in tools
      assert "Write" in tools
      assert "MultiEdit" in tools
    end

    test "Bash has both block and advisory severity levels" do
      {:ok, result} = SecurityGuidancePlugin.handle_action("covered_tools", %{}, [])
      bash = Enum.find(result.covered_tools, &(&1.tool == "Bash"))
      assert :block in bash.severity
      assert :advisory in bash.severity
    end

    test "Agent has advisory-only severity" do
      {:ok, result} = SecurityGuidancePlugin.handle_action("covered_tools", %{}, [])
      agent = Enum.find(result.covered_tools, &(&1.tool == "Agent"))
      assert agent.severity == [:advisory]
    end

    test "mentions uncovered tools" do
      {:ok, result} = SecurityGuidancePlugin.handle_action("covered_tools", %{}, [])
      assert is_list(result.uncovered_tools)
      assert "Read" in result.uncovered_tools
    end
  end

  # ---------------------------------------------------------------------------
  # handle_action/3 — pattern_summary
  # ---------------------------------------------------------------------------

  describe "handle_action/3 — pattern_summary" do
    test "returns :ok tuple with categories map" do
      assert {:ok, result} = SecurityGuidancePlugin.handle_action("pattern_summary", %{}, [])
      assert is_map(result.categories)
    end

    test "total_pattern_count is positive" do
      {:ok, result} = SecurityGuidancePlugin.handle_action("pattern_summary", %{}, [])
      assert result.total_pattern_count > 0
    end

    test "total pattern count matches sum of category counts" do
      {:ok, result} = SecurityGuidancePlugin.handle_action("pattern_summary", %{}, [])

      manual_sum =
        result.categories
        |> Map.values()
        |> Enum.reduce(0, fn %{count: c}, acc -> acc + c end)

      assert result.total_pattern_count == manual_sum
    end

    test "bash_critical category exists with count >= 8" do
      {:ok, result} = SecurityGuidancePlugin.handle_action("pattern_summary", %{}, [])
      bash_crit = Map.get(result.categories, "bash_critical")
      assert bash_crit != nil
      assert bash_crit.count >= 8
    end

    test "ssrf_block category exists" do
      {:ok, result} = SecurityGuidancePlugin.handle_action("pattern_summary", %{}, [])
      assert Map.has_key?(result.categories, "ssrf_block")
    end

    test "prompt_injection category exists" do
      {:ok, result} = SecurityGuidancePlugin.handle_action("pattern_summary", %{}, [])
      assert Map.has_key?(result.categories, "prompt_injection")
    end
  end

  # ---------------------------------------------------------------------------
  # handle_action/3 — hook_status
  # ---------------------------------------------------------------------------

  describe "handle_action/3 — hook_status" do
    test "returns :ok tuple with installation metadata" do
      assert {:ok, result} = SecurityGuidancePlugin.handle_action("hook_status", %{}, [])
      assert is_integer(result.installed_copies)
      assert is_integer(result.active_copies)
      assert is_integer(result.covered_tool_count)
    end

    test "covered_tool_count equals 8" do
      {:ok, result} = SecurityGuidancePlugin.handle_action("hook_status", %{}, [])
      assert result.covered_tool_count == 8
    end

    test "plugin_version matches module version" do
      {:ok, result} = SecurityGuidancePlugin.handle_action("hook_status", %{}, [])
      assert result.plugin_version == SecurityGuidancePlugin.plugin_version()
    end

    test "install_paths is a list" do
      {:ok, result} = SecurityGuidancePlugin.handle_action("hook_status", %{}, [])
      assert is_list(result.install_paths)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_action/3 — scan_history
  # ---------------------------------------------------------------------------

  describe "handle_action/3 — scan_history" do
    test "returns :ok tuple with log metadata" do
      assert {:ok, result} = SecurityGuidancePlugin.handle_action("scan_history", %{}, [])
      assert is_integer(result.total_lines)
      assert is_list(result.entries)
    end

    test "returned_lines does not exceed requested lines" do
      assert {:ok, result} = SecurityGuidancePlugin.handle_action("scan_history", %{"lines" => 10}, [])
      assert result.returned_lines <= 10
    end

    test "handles missing log file gracefully" do
      # Since the debug log may or may not exist in test env, we just verify no crash
      assert {:ok, _result} = SecurityGuidancePlugin.handle_action("scan_history", %{}, [])
    end
  end

  # ---------------------------------------------------------------------------
  # handle_action/3 — unknown action
  # ---------------------------------------------------------------------------

  describe "handle_action/3 — unknown action" do
    test "returns {:error, {:unknown_action, action}} for unknown actions" do
      assert {:error, {:unknown_action, "nonexistent"}} =
               SecurityGuidancePlugin.handle_action("nonexistent", %{}, [])
    end
  end

  # ---------------------------------------------------------------------------
  # nav_items/0
  # ---------------------------------------------------------------------------

  describe "nav_items/0" do
    test "returns a non-empty list of nav tuples" do
      items = SecurityGuidancePlugin.nav_items()
      assert is_list(items) and length(items) > 0
    end

    test "each nav item is a 3-tuple with binary label and path" do
      for {label, path, _icon} <- SecurityGuidancePlugin.nav_items() do
        assert is_binary(label)
        assert is_binary(path)
      end
    end

    test "nav paths are under /plugins/security_guidance/" do
      for {_label, path, _icon} <- SecurityGuidancePlugin.nav_items() do
        assert String.starts_with?(path, "/plugins/security_guidance/")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # dashboard_widgets/0
  # ---------------------------------------------------------------------------

  describe "dashboard_widgets/0" do
    test "returns at least one widget definition" do
      widgets = SecurityGuidancePlugin.dashboard_widgets()
      assert is_list(widgets) and length(widgets) >= 1
    end

    test "each widget has required keys" do
      for widget <- SecurityGuidancePlugin.dashboard_widgets() do
        assert Map.has_key?(widget, :id)
        assert Map.has_key?(widget, :name)
        assert Map.has_key?(widget, :category)
        assert Map.has_key?(widget, :plugin)
      end
    end

    test "widgets belong to :plugin category" do
      for widget <- SecurityGuidancePlugin.dashboard_widgets() do
        assert widget.category == :plugin
      end
    end
  end
end
