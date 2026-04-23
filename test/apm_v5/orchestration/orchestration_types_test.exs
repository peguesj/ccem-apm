defmodule ApmV5.Orchestration.OrchestrationTypesTest do
  use ExUnit.Case, async: true

  alias ApmV5.Orchestration.OrchestrationManager
  alias ApmV5.Orchestration.OrchestrationRunStore
  alias ApmV5.WorkflowRegistry
  alias ApmV5.Plugins.Orchestration.OrchestrationPlugin

  @moduletag :orchestration

  # ---------------------------------------------------------------------------
  # OrchestrationManager — type field on run struct
  # ---------------------------------------------------------------------------

  describe "OrchestrationManager run struct" do
    test "start_run/2 defaults orchestration_type to :workflow" do
      steps = [%{id: "a", label: "A", type: :action}]
      edges = []
      {:ok, run} = OrchestrationManager.start_run(%{steps: steps, edges: edges}, [])
      assert run.orchestration_type == :workflow
    end

    test "start_run/2 accepts explicit :pipeline type" do
      steps = [%{id: "a", label: "A", type: :action}, %{id: "b", label: "B", type: :terminal}]
      edges = [%{source: "a", target: "b"}]
      {:ok, run} = OrchestrationManager.start_run(
        %{steps: steps, edges: edges, orchestration_type: :pipeline},
        []
      )
      assert run.orchestration_type == :pipeline
    end

    test "start_run/2 accepts :maintenance type with schedule" do
      steps = [%{id: "a", label: "Health Check", type: :action}]
      {:ok, run} = OrchestrationManager.start_run(
        %{steps: steps, edges: [], orchestration_type: :maintenance, schedule: "0 * * * *"},
        []
      )
      assert run.orchestration_type == :maintenance
      assert run.metadata.schedule == "0 * * * *"
    end

    test "start_run/2 accepts :sync type with source and target" do
      steps = [%{id: "a", label: "Reconcile", type: :action}]
      {:ok, run} = OrchestrationManager.start_run(
        %{steps: steps, edges: [], orchestration_type: :sync, source: "plane", target: "ets"},
        []
      )
      assert run.orchestration_type == :sync
      assert run.metadata.source == "plane"
      assert run.metadata.target == "ets"
    end

    test "start_run/2 accepts :formation type" do
      steps = [%{id: "w1", label: "Wave 1", type: :action}]
      {:ok, run} = OrchestrationManager.start_run(
        %{steps: steps, edges: [], orchestration_type: :formation},
        []
      )
      assert run.orchestration_type == :formation
    end

    test "start_run/2 accepts :autonomous type" do
      steps = [%{id: "d", label: "Decide", type: :decision}]
      {:ok, run} = OrchestrationManager.start_run(
        %{steps: steps, edges: [], orchestration_type: :autonomous},
        []
      )
      assert run.orchestration_type == :autonomous
    end

    test "run struct includes orchestration_type in PubSub broadcast payload" do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "orchestration:runs")
      steps = [%{id: "s1", label: "Step", type: :action}]
      {:ok, run} = OrchestrationManager.start_run(
        %{steps: steps, edges: [], orchestration_type: :pipeline},
        []
      )
      # Allow broadcast to arrive
      assert_receive {:run_started, ^run}, 500
    end
  end

  # ---------------------------------------------------------------------------
  # Type validation — :pipeline rejects cycles
  # ---------------------------------------------------------------------------

  describe "pipeline type validation" do
    test "start_run/2 returns error when :pipeline has a back-edge (cycle)" do
      steps = [
        %{id: "a", label: "A", type: :action},
        %{id: "b", label: "B", type: :action}
      ]
      # a -> b -> a is a cycle
      edges = [
        %{source: "a", target: "b"},
        %{source: "b", target: "a"}
      ]
      result = OrchestrationManager.start_run(
        %{steps: steps, edges: edges, orchestration_type: :pipeline},
        []
      )
      assert {:error, {:cycle_detected, _}} = result
    end

    test "start_run/2 accepts :pipeline with valid linear DAG" do
      steps = [
        %{id: "1", label: "Build", type: :action},
        %{id: "2", label: "Test", type: :gate},
        %{id: "3", label: "Deploy", type: :terminal}
      ]
      edges = [
        %{source: "1", target: "2"},
        %{source: "2", target: "3"}
      ]
      assert {:ok, run} = OrchestrationManager.start_run(
        %{steps: steps, edges: edges, orchestration_type: :pipeline},
        []
      )
      assert run.orchestration_type == :pipeline
    end
  end

  # ---------------------------------------------------------------------------
  # Type validation — :maintenance requires schedule
  # ---------------------------------------------------------------------------

  describe "maintenance type validation" do
    test "start_run/2 returns error when :maintenance missing schedule" do
      steps = [%{id: "h", label: "Health", type: :action}]
      result = OrchestrationManager.start_run(
        %{steps: steps, edges: [], orchestration_type: :maintenance},
        []
      )
      assert {:error, {:missing_required_param, :schedule}} = result
    end
  end

  # ---------------------------------------------------------------------------
  # Type validation — :sync requires source and target
  # ---------------------------------------------------------------------------

  describe "sync type validation" do
    test "start_run/2 returns error when :sync missing source" do
      steps = [%{id: "r", label: "Reconcile", type: :action}]
      result = OrchestrationManager.start_run(
        %{steps: steps, edges: [], orchestration_type: :sync, target: "ets"},
        []
      )
      assert {:error, {:missing_required_param, :source}} = result
    end

    test "start_run/2 returns error when :sync missing target" do
      steps = [%{id: "r", label: "Reconcile", type: :action}]
      result = OrchestrationManager.start_run(
        %{steps: steps, edges: [], orchestration_type: :sync, source: "plane"},
        []
      )
      assert {:error, {:missing_required_param, :target}} = result
    end
  end

  # ---------------------------------------------------------------------------
  # OrchestrationRunStore — typed run storage and retrieval
  # ---------------------------------------------------------------------------

  describe "OrchestrationRunStore typed storage" do
    test "stores and retrieves runs by orchestration_type" do
      run_a = %{id: "ra-#{System.unique_integer([:positive])}", orchestration_type: :pipeline, status: :completed, steps: [], started_at: DateTime.utc_now()}
      run_b = %{id: "rb-#{System.unique_integer([:positive])}", orchestration_type: :sync, status: :running, steps: [], started_at: DateTime.utc_now()}
      OrchestrationRunStore.put(run_a)
      OrchestrationRunStore.put(run_b)
      # Flush async casts via a synchronous call
      _ = OrchestrationRunStore.list()

      pipeline_runs = OrchestrationRunStore.list_by_type(:pipeline)
      assert Enum.any?(pipeline_runs, &(&1.id == run_a.id))
      refute Enum.any?(pipeline_runs, &(&1.id == run_b.id))
    end

    test "list_by_type/1 returns empty list for type with no runs" do
      result = OrchestrationRunStore.list_by_type(:maintenance)
      assert is_list(result)
    end
  end

  # ---------------------------------------------------------------------------
  # WorkflowRegistry — typed workflow templates
  # ---------------------------------------------------------------------------

  describe "WorkflowRegistry typed templates" do
    test "skill_chain workflow exists and has type :pipeline" do
      wf = WorkflowRegistry.get_workflow("skill_chain")
      assert wf != nil
      assert wf.orchestration_type == :pipeline
    end

    test "devdrive_sync workflow exists and has type :sync" do
      wf = WorkflowRegistry.get_workflow("devdrive_sync")
      assert wf != nil
      assert wf.orchestration_type == :sync
    end

    test "session_maintenance workflow exists and has type :maintenance" do
      wf = WorkflowRegistry.get_workflow("session_maintenance")
      assert wf != nil
      assert wf.orchestration_type == :maintenance
    end

    test "ralph workflow retains :autonomous type" do
      wf = WorkflowRegistry.get_workflow("ralph")
      assert wf != nil
      assert wf.orchestration_type == :autonomous
    end

    test "upm workflow retains :formation type" do
      wf = WorkflowRegistry.get_workflow("upm")
      assert wf != nil
      assert wf.orchestration_type == :formation
    end

    test "register_workflow/2 accepts a typed workflow map" do
      wf = %{
        id: "test_wf_#{System.unique_integer([:positive])}",
        title: "Test Workflow",
        description: "For testing",
        orchestration_type: :workflow,
        steps: [],
        edges: []
      }
      :ok = WorkflowRegistry.register_workflow(wf.id, wf)
      assert WorkflowRegistry.get_workflow(wf.id) == wf
    end
  end

  # ---------------------------------------------------------------------------
  # OrchestrationPlugin — list_types action
  # ---------------------------------------------------------------------------

  describe "OrchestrationPlugin list_types action" do
    test "handle_action list_types returns all 6 orchestration types" do
      {:ok, result} = OrchestrationPlugin.handle_action("list_types", %{}, [])
      types = result.types
      assert is_list(types)
      type_names = Enum.map(types, & &1.type)
      assert :pipeline in type_names
      assert :workflow in type_names
      assert :maintenance in type_names
      assert :sync in type_names
      assert :formation in type_names
      assert :autonomous in type_names
    end

    test "list_types result entries each have type, description, required_params" do
      {:ok, %{types: types}} = OrchestrationPlugin.handle_action("list_types", %{}, [])
      Enum.each(types, fn entry ->
        assert Map.has_key?(entry, :type)
        assert Map.has_key?(entry, :description)
        assert Map.has_key?(entry, :required_params)
        assert is_atom(entry.type)
        assert is_binary(entry.description)
        assert is_list(entry.required_params)
      end)
    end

    test "list_types is exposed in list_endpoints" do
      endpoints = OrchestrationPlugin.list_endpoints()
      actions = Enum.map(endpoints, & &1.action)
      assert "list_types" in actions
    end
  end

  # ---------------------------------------------------------------------------
  # otel_attributes/1 — OpenTelemetry gen_ai attribute mapping
  # ---------------------------------------------------------------------------

  describe "otel_attributes/1" do
    test "maps run metadata to gen_ai semantic convention attributes" do
      run = %{
        id: "run-otel-1",
        orchestration_type: :pipeline,
        status: :running,
        started_at: DateTime.utc_now(),
        metadata: %{}
      }
      attrs = OrchestrationManager.otel_attributes(run)
      assert attrs["gen_ai.operation.name"] == "pipeline"
      assert attrs["gen_ai.system"] == "ccem_apm"
      assert is_binary(attrs["gen_ai.request.id"])
    end

    test "autonomous type maps gen_ai.operation.name to autonomous" do
      run = %{id: "r2", orchestration_type: :autonomous, status: :running, started_at: DateTime.utc_now(), metadata: %{}}
      attrs = OrchestrationManager.otel_attributes(run)
      assert attrs["gen_ai.operation.name"] == "autonomous"
    end
  end
end
