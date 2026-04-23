defmodule ApmV5.Plugins.Orchestration.OrchestrationPluginTest do
  use ExUnit.Case, async: false

  @moduletag :orchestration

  alias ApmV5.Plugins.Orchestration.OrchestrationPlugin
  alias ApmV5.Orchestration.OrchestrationManager
  alias ApmV5.Orchestration.OrchestrationRunStore

  setup do
    for mod <- [OrchestrationManager, OrchestrationRunStore] do
      case Process.whereis(mod) do
        nil -> {:ok, _} = mod.start_link()
        _pid -> :ok
      end
    end

    :ets.delete_all_objects(:orchestration_runs)
    :ets.delete_all_objects(:orchestration_run_history)
    :ok
  end

  describe "PluginBehaviour contract" do
    test "plugin_name returns orchestration" do
      assert OrchestrationPlugin.plugin_name() == "orchestration"
    end

    test "plugin_description is a non-empty string" do
      desc = OrchestrationPlugin.plugin_description()
      assert is_binary(desc) and desc != ""
    end

    test "plugin_version is a semver string" do
      assert OrchestrationPlugin.plugin_version() =~ ~r/^\d+\.\d+\.\d+$/
    end

    test "plugin_scope is :orchestration" do
      assert OrchestrationPlugin.plugin_scope() == :orchestration
    end

    test "list_endpoints returns a non-empty list of maps" do
      endpoints = OrchestrationPlugin.list_endpoints()
      assert is_list(endpoints)
      assert length(endpoints) > 0
      assert Enum.all?(endpoints, &is_map/1)
      assert Enum.all?(endpoints, &Map.has_key?(&1, :action))
    end

    test "nav_items returns list of tuples" do
      items = OrchestrationPlugin.nav_items()
      assert is_list(items)
      assert length(items) > 0
    end

    test "dashboard_widgets returns a non-empty list" do
      widgets = OrchestrationPlugin.dashboard_widgets()
      assert is_list(widgets)
      assert length(widgets) > 0
      assert hd(widgets).id == "orchestration_summary"
    end

    test "orchestration_topology returns a valid topology" do
      topo = OrchestrationPlugin.orchestration_topology()
      assert is_map(topo)
      assert is_list(topo.steps)
      assert is_list(topo.edges)
      assert is_list(topo.gates)
      assert length(topo.steps) > 0
    end
  end

  describe "handle_action/3" do
    test "start_run — starts a run for a valid workflow" do
      assert {:ok, result} =
               OrchestrationPlugin.handle_action("start_run", %{"workflow_id" => "ralph"}, [])

      assert result.workflow_id == "ralph"
      assert result.status == :pending
    end

    test "start_run — error without workflow_id" do
      assert {:error, {:missing_param, _}} =
               OrchestrationPlugin.handle_action("start_run", %{}, [])
    end

    test "get_status — returns status for active run" do
      {:ok, %{run_id: run_id}} =
        OrchestrationPlugin.handle_action("start_run", %{"workflow_id" => "ralph"}, [])

      assert {:ok, status} =
               OrchestrationPlugin.handle_action("get_status", %{"run_id" => run_id}, [])

      assert status.run_id == run_id
      assert status.progress =~ ~r/\d+\/\d+/
    end

    test "get_status — error without run_id" do
      assert {:error, {:missing_param, _}} =
               OrchestrationPlugin.handle_action("get_status", %{}, [])
    end

    test "dry_run — returns execution order" do
      assert {:ok, result} =
               OrchestrationPlugin.handle_action("dry_run", %{"workflow_id" => "ralph"}, [])

      assert result.workflow_id == "ralph"
      assert is_list(result.execution_order)
    end

    test "list_history — returns empty initially" do
      assert {:ok, result} =
               OrchestrationPlugin.handle_action("list_history", %{}, [])

      assert result.count == 0
      assert result.runs == []
    end

    test "unknown action — returns error" do
      assert {:error, {:unknown_action, "bogus"}} =
               OrchestrationPlugin.handle_action("bogus", %{}, [])
    end
  end
end
