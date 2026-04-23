defmodule ApmV5.Plugins.SkillDrift.SkillDriftPluginTest do
  use ExUnit.Case, async: true

  alias ApmV5.Plugins.SkillDrift.SkillDriftPlugin

  @tmp_dir System.tmp_dir!()

  # ---------------------------------------------------------------------------
  # Test helpers
  # ---------------------------------------------------------------------------

  defp create_test_skills_dir(test_name) do
    dir = Path.join([@tmp_dir, "skill_drift_test_#{test_name}_#{System.unique_integer([:positive])}"])
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  defp write_skill(dir, skill_name, content) do
    skill_dir = Path.join(dir, skill_name)
    File.mkdir_p!(skill_dir)
    path = Path.join(skill_dir, "SKILL.md")
    File.write!(path, content)
    path
  end

  defp cleanup(dir) do
    File.rm_rf!(dir)
  end

  # ---------------------------------------------------------------------------
  # PluginBehaviour contract
  # ---------------------------------------------------------------------------

  describe "PluginBehaviour contract" do
    test "plugin_name/0 returns expected machine-friendly name" do
      assert SkillDriftPlugin.plugin_name() == "skill_drift"
    end

    test "plugin_description/0 returns a non-empty string" do
      desc = SkillDriftPlugin.plugin_description()
      assert is_binary(desc) and byte_size(desc) > 0
    end

    test "plugin_version/0 returns a semver-like string" do
      version = SkillDriftPlugin.plugin_version()
      assert Regex.match?(~r/^\d+\.\d+\.\d+$/, version)
    end

    test "plugin_scope/0 returns :apm" do
      assert SkillDriftPlugin.plugin_scope() == :apm
    end

    test "default_enabled?/0 returns true" do
      assert SkillDriftPlugin.default_enabled?() == true
    end

    test "supervisor_children/0 returns empty list" do
      assert SkillDriftPlugin.supervisor_children() == []
    end

    test "plugin_live_module/0 returns SkillDriftLive" do
      assert SkillDriftPlugin.plugin_live_module() == ApmV5Web.SkillDriftLive
    end

    test "plugin_integrations/0 returns empty list" do
      assert SkillDriftPlugin.plugin_integrations() == []
    end

    test "settings_path/0 returns nil" do
      assert SkillDriftPlugin.settings_path() == nil
    end
  end

  # ---------------------------------------------------------------------------
  # list_endpoints/0
  # ---------------------------------------------------------------------------

  describe "list_endpoints/0" do
    test "returns a list of 3 endpoint descriptors" do
      endpoints = SkillDriftPlugin.list_endpoints()
      assert is_list(endpoints)
      assert length(endpoints) == 3
    end

    test "all endpoints have :action and :description keys" do
      for ep <- SkillDriftPlugin.list_endpoints() do
        assert is_binary(ep.action)
        assert is_binary(ep.description)
      end
    end

    test "expected actions are present" do
      actions = SkillDriftPlugin.list_endpoints() |> Enum.map(& &1.action)
      assert "skill_drift_scan" in actions
      assert "skill_drift_report" in actions
      assert "skill_drift_fix" in actions
    end
  end

  # ---------------------------------------------------------------------------
  # handle_action/3 — skill_drift_scan
  # ---------------------------------------------------------------------------

  describe "handle_action/3 — skill_drift_scan" do
    test "returns :ok with scan results for empty directory" do
      dir = create_test_skills_dir("scan_empty")

      assert {:ok, result} =
               SkillDriftPlugin.handle_action("skill_drift_scan", %{"skills_path" => dir}, [])

      assert result.scanned_files == 0
      assert result.total_findings == 0
      assert result.findings == []
      cleanup(dir)
    end

    test "detects wrong port reference" do
      dir = create_test_skills_dir("scan_port")

      write_skill(dir, "test-skill", """
      # Test Skill
      APM endpoint: http://localhost:3031/api/v2/agents
      """)

      assert {:ok, result} =
               SkillDriftPlugin.handle_action("skill_drift_scan", %{"skills_path" => dir}, [])

      assert result.scanned_files == 1
      assert result.total_findings >= 1

      port_findings = Enum.filter(result.findings, &(&1.drift_type == :wrong_port))
      assert length(port_findings) >= 1

      finding = hd(port_findings)
      assert finding.found == "localhost:3031"
      assert finding.expected == "localhost:3032"
      assert finding.severity == :critical
      assert finding.fixable == true
      cleanup(dir)
    end

    test "does not flag correct port 3032" do
      dir = create_test_skills_dir("scan_correct_port")

      write_skill(dir, "good-skill", """
      # Good Skill
      APM endpoint: http://localhost:3032/api/v2/agents
      """)

      assert {:ok, result} =
               SkillDriftPlugin.handle_action("skill_drift_scan", %{"skills_path" => dir}, [])

      port_findings = Enum.filter(result.findings, &(&1.drift_type == :wrong_port))
      assert port_findings == []
      cleanup(dir)
    end

    test "detects stale version reference" do
      dir = create_test_skills_dir("scan_version")
      current = SkillDriftPlugin.current_app_version()
      # Use a deliberately different version
      stale = "0.0.1"

      write_skill(dir, "stale-skill", """
      # Stale Skill
      APM version: v#{stale}
      CCEM APM compatibility
      """)

      assert {:ok, result} =
               SkillDriftPlugin.handle_action("skill_drift_scan", %{"skills_path" => dir}, [])

      version_findings = Enum.filter(result.findings, &(&1.drift_type == :stale_version))

      if current != stale do
        assert length(version_findings) >= 1
        finding = hd(version_findings)
        assert finding.severity == :warning
        assert finding.fixable == true
      end

      cleanup(dir)
    end

    test "detects multiple drift types in one file" do
      dir = create_test_skills_dir("scan_multi")

      write_skill(dir, "multi-drift", """
      # Multi Drift Skill
      APM endpoint: http://localhost:3031/api/v2/agents
      Version: v0.0.1
      CCEM APM hook_version: v7
      """)

      assert {:ok, result} =
               SkillDriftPlugin.handle_action("skill_drift_scan", %{"skills_path" => dir}, [])

      assert result.total_findings >= 2
      drift_types = result.findings |> Enum.map(& &1.drift_type) |> Enum.uniq()
      assert :wrong_port in drift_types
      cleanup(dir)
    end

    test "scans multiple skill directories" do
      dir = create_test_skills_dir("scan_multiple")
      write_skill(dir, "skill-a", "# Skill A\nAPM: http://localhost:3031/api\n")
      write_skill(dir, "skill-b", "# Skill B\nAPM: http://localhost:3032/api\n")

      assert {:ok, result} =
               SkillDriftPlugin.handle_action("skill_drift_scan", %{"skills_path" => dir}, [])

      assert result.scanned_files == 2
      cleanup(dir)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_action/3 — skill_drift_report
  # ---------------------------------------------------------------------------

  describe "handle_action/3 — skill_drift_report" do
    test "returns grouped report with summary" do
      dir = create_test_skills_dir("report_basic")

      write_skill(dir, "drifted", """
      # Drifted
      http://localhost:3031/api/v2/agents
      """)

      assert {:ok, result} =
               SkillDriftPlugin.handle_action("skill_drift_report", %{"skills_path" => dir}, [])

      assert is_map(result.summary)
      assert Map.has_key?(result.summary, :scanned)
      assert Map.has_key?(result.summary, :clean)
      assert Map.has_key?(result.summary, :critical)
      assert Map.has_key?(result.summary, :warning)
      assert Map.has_key?(result.summary, :info)
      cleanup(dir)
    end

    test "groups findings by severity" do
      dir = create_test_skills_dir("report_grouped")

      write_skill(dir, "critical-skill", """
      # Critical
      http://localhost:3031/api
      """)

      assert {:ok, result} =
               SkillDriftPlugin.handle_action("skill_drift_report", %{"skills_path" => dir}, [])

      assert is_map(result.findings_by_severity)
      assert Map.has_key?(result.findings_by_severity, :critical)
      assert Map.has_key?(result.findings_by_severity, :warning)
      assert Map.has_key?(result.findings_by_severity, :info)
      cleanup(dir)
    end

    test "clean count reflects files with no drift" do
      dir = create_test_skills_dir("report_clean")
      write_skill(dir, "clean-1", "# Clean skill\nNo APM references\n")
      write_skill(dir, "clean-2", "# Also clean\nNothing here\n")

      assert {:ok, result} =
               SkillDriftPlugin.handle_action("skill_drift_report", %{"skills_path" => dir}, [])

      assert result.summary.scanned == 2
      assert result.summary.clean == 2
      assert result.summary.critical == 0
      assert result.summary.warning == 0
      cleanup(dir)
    end

    test "includes current_version in report" do
      dir = create_test_skills_dir("report_version")

      assert {:ok, result} =
               SkillDriftPlugin.handle_action("skill_drift_report", %{"skills_path" => dir}, [])

      assert is_binary(result.current_version)
      cleanup(dir)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_action/3 — skill_drift_fix
  # ---------------------------------------------------------------------------

  describe "handle_action/3 — skill_drift_fix" do
    test "fixes wrong port references" do
      dir = create_test_skills_dir("fix_port")

      path =
        write_skill(dir, "fixable", """
        # Fixable
        APM endpoint: http://localhost:3031/api/v2/agents
        """)

      assert {:ok, result} =
               SkillDriftPlugin.handle_action("skill_drift_fix", %{"skills_path" => dir}, [])

      assert result.fixes_applied >= 1

      # Verify file was actually updated
      {:ok, content} = File.read(path)
      assert String.contains?(content, "localhost:3032")
      refute String.contains?(content, "localhost:3031")
      cleanup(dir)
    end

    test "dry_run does not modify files" do
      dir = create_test_skills_dir("fix_dry")

      path =
        write_skill(dir, "dry-skill", """
        # Dry Run
        APM: http://localhost:3031/api
        """)

      {:ok, original} = File.read(path)

      assert {:ok, result} =
               SkillDriftPlugin.handle_action(
                 "skill_drift_fix",
                 %{"skills_path" => dir, "dry_run" => true},
                 []
               )

      assert result.dry_run == true
      assert result.fixes_applied == 0

      {:ok, after_content} = File.read(path)
      assert original == after_content
      cleanup(dir)
    end

    test "reports zero fixes for clean directory" do
      dir = create_test_skills_dir("fix_clean")
      write_skill(dir, "clean", "# Clean\nNo issues\n")

      assert {:ok, result} =
               SkillDriftPlugin.handle_action("skill_drift_fix", %{"skills_path" => dir}, [])

      assert result.fixes_applied == 0
      assert result.fixes_available == 0
      cleanup(dir)
    end

    test "fixes version references" do
      dir = create_test_skills_dir("fix_version")
      current = SkillDriftPlugin.current_app_version()

      path =
        write_skill(dir, "ver-skill", """
        # Version Skill
        CCEM APM version: v0.0.1
        """)

      assert {:ok, _result} =
               SkillDriftPlugin.handle_action("skill_drift_fix", %{"skills_path" => dir}, [])

      {:ok, content} = File.read(path)

      if current != "0.0.1" do
        assert String.contains?(content, "v#{current}")
      end

      cleanup(dir)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_action/3 — unknown action
  # ---------------------------------------------------------------------------

  describe "handle_action/3 — unknown action" do
    test "returns {:error, {:unknown_action, action}} for unknown actions" do
      assert {:error, {:unknown_action, "nonexistent"}} =
               SkillDriftPlugin.handle_action("nonexistent", %{}, [])
    end
  end

  # ---------------------------------------------------------------------------
  # nav_items/0
  # ---------------------------------------------------------------------------

  describe "nav_items/0" do
    test "returns a non-empty list of nav tuples" do
      items = SkillDriftPlugin.nav_items()
      assert is_list(items) and length(items) > 0
    end

    test "each nav item is a 3-tuple with binary label and path" do
      for {label, path, _icon} <- SkillDriftPlugin.nav_items() do
        assert is_binary(label)
        assert is_binary(path)
      end
    end

    test "nav paths include /skill-drift" do
      paths = SkillDriftPlugin.nav_items() |> Enum.map(fn {_, path, _} -> path end)
      assert Enum.any?(paths, &String.contains?(&1, "/skill-drift"))
    end
  end

  # ---------------------------------------------------------------------------
  # dashboard_widgets/0
  # ---------------------------------------------------------------------------

  describe "dashboard_widgets/0" do
    test "returns at least one widget definition" do
      widgets = SkillDriftPlugin.dashboard_widgets()
      assert is_list(widgets) and length(widgets) >= 1
    end

    test "each widget has required keys" do
      for widget <- SkillDriftPlugin.dashboard_widgets() do
        assert Map.has_key?(widget, :id)
        assert Map.has_key?(widget, :name)
        assert Map.has_key?(widget, :category)
        assert Map.has_key?(widget, :plugin)
      end
    end

    test "widgets belong to :plugin category" do
      for widget <- SkillDriftPlugin.dashboard_widgets() do
        assert widget.category == :plugin
      end
    end

    test "widget has correct plugin name" do
      widget = hd(SkillDriftPlugin.dashboard_widgets())
      assert widget.plugin == "skill_drift"
    end

    test "widget includes v2 schema fields" do
      widget = hd(SkillDriftPlugin.dashboard_widgets())
      assert Map.has_key?(widget, :editable)
      assert Map.has_key?(widget, :pinnable)
      assert Map.has_key?(widget, :supported_scopes)
      assert Map.has_key?(widget, :display_order)
    end
  end

  # ---------------------------------------------------------------------------
  # current_app_version/0
  # ---------------------------------------------------------------------------

  describe "current_app_version/0" do
    test "returns a version string" do
      ver = SkillDriftPlugin.current_app_version()
      assert is_binary(ver)
      assert Regex.match?(~r/^\d+\.\d+\.\d+$/, ver)
    end
  end

  # ---------------------------------------------------------------------------
  # known_router_paths/0
  # ---------------------------------------------------------------------------

  describe "known_router_paths/0" do
    test "returns a list of strings" do
      paths = SkillDriftPlugin.known_router_paths()
      assert is_list(paths)

      if paths != [] do
        assert Enum.all?(paths, &is_binary/1)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # API endpoint integration (controller dispatch)
  # ---------------------------------------------------------------------------

  describe "API endpoint integration" do
    test "scan action is callable via handle_action" do
      dir = create_test_skills_dir("api_scan")
      assert {:ok, _} = SkillDriftPlugin.handle_action("skill_drift_scan", %{"skills_path" => dir}, [])
      cleanup(dir)
    end

    test "report action is callable via handle_action" do
      dir = create_test_skills_dir("api_report")

      assert {:ok, _} =
               SkillDriftPlugin.handle_action("skill_drift_report", %{"skills_path" => dir}, [])

      cleanup(dir)
    end

    test "fix action is callable via handle_action" do
      dir = create_test_skills_dir("api_fix")

      assert {:ok, _} =
               SkillDriftPlugin.handle_action("skill_drift_fix", %{"skills_path" => dir}, [])

      cleanup(dir)
    end
  end
end
