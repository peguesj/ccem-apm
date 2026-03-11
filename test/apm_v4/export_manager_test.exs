defmodule ApmV4.ExportManagerTest do
  use ExUnit.Case, async: false

  alias ApmV4.ExportManager
  alias ApmV4.AgentRegistry
  alias ApmV4.AlertRulesEngine
  alias ApmV4.SloEngine
  alias ApmV4.MetricsCollector
  alias ApmV4.AuditLog

  @tmp_dir System.tmp_dir!()
           |> Path.join("apm_export_test_#{System.unique_integer([:positive])}")

  setup do
    ApmV4.GenServerHelpers.ensure_processes_alive()
    # Ensure PubSub is running
    unless GenServer.whereis(ApmV4.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ApmV4.PubSub})
    end

    # Clear state of globally-started GenServers instead of restarting them
    if Process.whereis(AgentRegistry), do: AgentRegistry.clear_all()
    # AlertRulesEngine doesn't have clear_all - state persists across tests
    if Process.whereis(SloEngine), do: SloEngine.clear_all()
    if Process.whereis(MetricsCollector), do: MetricsCollector.clear_all()
    if Process.whereis(AuditLog), do: AuditLog.clear_all()

    Application.put_env(:apm_v4, :audit_log_dir, @tmp_dir)

    on_exit(fn ->
      File.rm_rf!(@tmp_dir)
      Application.delete_env(:apm_v4, :audit_log_dir)
    end)

    :ok
  end

  describe "export/0" do
    test "returns all sections with manifest and checksum" do
      AgentRegistry.register_agent("test-agent-1", %{name: "Agent One"})

      result = ExportManager.export()

      assert %{manifest: manifest, checksum: checksum} = result
      assert manifest.version != nil
      assert manifest.exported_at != nil
      assert manifest.hostname != nil
      assert is_list(manifest.sections)
      assert is_binary(checksum)
      assert String.length(checksum) == 64

      assert Map.has_key?(result, :agents)
      assert Map.has_key?(result, :sessions)
      assert Map.has_key?(result, :metrics)
      assert Map.has_key?(result, :slos)
      assert Map.has_key?(result, :alert_rules)
      assert Map.has_key?(result, :alert_history)
      assert Map.has_key?(result, :audit_log)
    end

    test "includes registered agents in export" do
      AgentRegistry.register_agent("a1", %{name: "Alpha"})
      AgentRegistry.register_agent("a2", %{name: "Beta"})

      result = ExportManager.export()
      ids = Enum.map(result.agents, & &1.id)

      assert "a1" in ids
      assert "a2" in ids
    end
  end

  describe "export/1 with sections filter" do
    test "returns only requested sections" do
      result = ExportManager.export(sections: [:agents, :slos])

      assert Map.has_key?(result, :agents)
      assert Map.has_key?(result, :slos)
      assert Map.has_key?(result, :manifest)
      assert Map.has_key?(result, :checksum)

      refute Map.has_key?(result, :metrics)
      refute Map.has_key?(result, :alert_rules)
      refute Map.has_key?(result, :alert_history)
      refute Map.has_key?(result, :audit_log)
      refute Map.has_key?(result, :sessions)
    end
  end

  describe "export_csv/1" do
    test "returns valid CSV with headers for agents" do
      AgentRegistry.register_agent("csv-agent", %{name: "CSV Agent", tier: 2})

      csv = ExportManager.export_csv(:agents)

      assert is_binary(csv)
      [header_line | data_lines] = String.split(csv, "\n", trim: true)

      assert header_line == "id,name,tier,status,project_name,agent_type,registered_at,last_seen"
      assert length(data_lines) >= 1

      first_row = hd(data_lines)
      assert String.contains?(first_row, "csv-agent")
    end

    test "returns valid CSV for audit_log" do
      AuditLog.log_sync("test_event", "tester", "resource1", %{})

      csv = ExportManager.export_csv(:audit_log)
      assert is_binary(csv)

      [header_line | _] = String.split(csv, "\n", trim: true)
      assert header_line == "id,timestamp,event_type,actor,resource"
    end

    test "returns error for unsupported section" do
      assert {:error, :unsupported_section} = ExportManager.export_csv(:metrics)
    end
  end

  describe "import/1" do
    test "validates checksum" do
      exported = ExportManager.export()
      assert {:ok, _summary} = ExportManager.import(exported)
    end

    test "rejects tampered data" do
      exported = ExportManager.export()
      tampered = Map.put(exported, :agents, [%{id: "fake", name: "Fake"}])

      assert {:error, :checksum_mismatch} = ExportManager.import(tampered)
    end

    test "rejects missing checksum" do
      data = %{manifest: %{version: "5.3.0"}}
      assert {:error, :missing_checksum} = ExportManager.import(data)
    end

    test "rejects incompatible version" do
      data = %{
        manifest: %{version: "3.0.0"},
        agents: []
      }

      checksum =
        data
        |> Jason.encode!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      data_with_checksum = Map.put(data, :checksum, checksum)
      assert {:error, :incompatible_version} = ExportManager.import(data_with_checksum)
    end

    test "restores agents" do
      AgentRegistry.register_agent("export-me", %{name: "Exported Agent"})
      exported = ExportManager.export()

      # Clear agents
      AgentRegistry.clear_all()
      assert AgentRegistry.list_agents() == []

      # Import
      assert {:ok, summary} = ExportManager.import(exported)
      assert summary.agents_imported >= 1

      restored = AgentRegistry.get_agent("export-me")
      assert restored != nil
      assert restored.name == "Exported Agent" || restored.name == "export-me"
    end
  end

  describe "round-trip" do
    test "export -> import -> verify data matches" do
      # Set up data
      AgentRegistry.register_agent("rt-agent", %{name: "RoundTrip"})
      SloEngine.record_event(:agent_availability, :ok)
      AuditLog.log_sync("rt_test", "system", "test_resource", %{})

      # Export
      exported = ExportManager.export()
      agent_count = length(exported.agents)
      assert agent_count >= 1

      # Clear and reimport
      AgentRegistry.clear_all()

      assert {:ok, summary} = ExportManager.import(exported)
      assert summary.agents_imported == agent_count

      # Verify agent restored
      agent = AgentRegistry.get_agent("rt-agent")
      assert agent != nil
    end
  end
end
