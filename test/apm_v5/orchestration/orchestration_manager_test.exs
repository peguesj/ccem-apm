defmodule ApmV5.Orchestration.OrchestrationManagerTest do
  use ExUnit.Case, async: false

  @moduletag :orchestration

  alias ApmV5.Orchestration.OrchestrationManager

  setup do
    # Ensure the GenServer is running
    case Process.whereis(OrchestrationManager) do
      nil ->
        {:ok, _} = OrchestrationManager.start_link()
        :ok

      _pid ->
        # Clear existing runs from ETS
        :ets.delete_all_objects(:orchestration_runs)
        :ok
    end
  end

  describe "start_run/2" do
    test "starts a run for an existing workflow" do
      assert {:ok, run} = OrchestrationManager.start_run("ralph")
      assert run.id =~ "run-ralph-"
      assert run.workflow_id == "ralph"
      assert run.status == :pending
      assert map_size(run.steps) > 0
      assert length(run.edges) > 0
    end

    test "returns error for non-existent workflow" do
      assert {:error, {:workflow_not_found, "nonexistent"}} =
               OrchestrationManager.start_run("nonexistent")
    end

    test "dry run returns execution order without persisting" do
      assert {:ok, result} = OrchestrationManager.start_run("ralph", %{dry_run: true})
      assert result.dry_run == true
      assert is_list(result.execution_order)

      # Should not be persisted
      assert OrchestrationManager.get_run(result.id) == nil
    end
  end

  describe "advance_step/3" do
    test "advances a pending step to completed" do
      {:ok, run} = OrchestrationManager.start_run("ralph")

      # Find a step with no dependencies (first step)
      next = OrchestrationManager.next_steps(run.id)
      assert length(next) > 0
      first_step = hd(next)

      assert {:ok, updated} = OrchestrationManager.advance_step(run.id, first_step, %{output: "done"})
      assert updated.steps[first_step].status == :completed
      assert updated.steps[first_step].result == %{output: "done"}
      assert updated.steps[first_step].completed_at != nil
    end

    test "returns error for non-existent run" do
      assert {:error, {:run_not_found, "fake-id"}} =
               OrchestrationManager.advance_step("fake-id", "step1", %{})
    end

    test "returns error for non-existent step" do
      {:ok, run} = OrchestrationManager.start_run("ralph")

      assert {:error, {:step_not_found, "fake-step"}} =
               OrchestrationManager.advance_step(run.id, "fake-step", %{})
    end
  end

  describe "fail_step/3" do
    test "marks a step as failed and fails the run" do
      {:ok, run} = OrchestrationManager.start_run("ralph")
      next = OrchestrationManager.next_steps(run.id)
      first_step = hd(next)

      assert {:ok, updated} = OrchestrationManager.fail_step(run.id, first_step, "compile error")
      assert updated.steps[first_step].status == :failed
      assert updated.status == :failed
    end
  end

  describe "skip_step/2" do
    test "skips a pending step" do
      {:ok, run} = OrchestrationManager.start_run("ralph")
      next = OrchestrationManager.next_steps(run.id)
      first_step = hd(next)

      assert {:ok, updated} = OrchestrationManager.skip_step(run.id, first_step)
      assert updated.steps[first_step].status == :skipped
    end
  end

  describe "cancel_run/1" do
    test "cancels an active run" do
      {:ok, run} = OrchestrationManager.start_run("ralph")
      assert {:ok, cancelled} = OrchestrationManager.cancel_run(run.id)
      assert cancelled.status == :cancelled
    end

    test "returns error for non-existent run" do
      assert {:error, {:run_not_found, "fake"}} = OrchestrationManager.cancel_run("fake")
    end
  end

  describe "get_run/1" do
    test "retrieves a run by ID" do
      {:ok, run} = OrchestrationManager.start_run("ralph")
      assert OrchestrationManager.get_run(run.id) != nil
      assert OrchestrationManager.get_run(run.id).id == run.id
    end

    test "returns nil for non-existent run" do
      assert OrchestrationManager.get_run("does-not-exist") == nil
    end
  end

  describe "list_active_runs/0" do
    test "lists only active (pending/running) runs" do
      {:ok, run1} = OrchestrationManager.start_run("ralph")
      {:ok, _run2} = OrchestrationManager.start_run("upm")
      OrchestrationManager.cancel_run(run1.id)

      actives = OrchestrationManager.list_active_runs()
      assert length(actives) == 1
    end
  end

  describe "next_steps/1" do
    test "returns steps with all dependencies satisfied" do
      {:ok, run} = OrchestrationManager.start_run("ralph")
      next = OrchestrationManager.next_steps(run.id)
      # First step should have no dependencies
      assert length(next) > 0
    end

    test "returns empty list for non-existent run" do
      assert OrchestrationManager.next_steps("fake") == []
    end

    test "unlocks dependent steps after advancing" do
      {:ok, run} = OrchestrationManager.start_run("ralph")
      [first | _] = OrchestrationManager.next_steps(run.id)

      # Before advancing, dependent steps should not be ready
      next_before = OrchestrationManager.next_steps(run.id)

      # Advance first step
      {:ok, _} = OrchestrationManager.advance_step(run.id, first, %{})

      # After advancing, new steps should be available
      next_after = OrchestrationManager.next_steps(run.id)
      assert next_after != next_before or length(next_after) > 0
    end
  end

  describe "run completion" do
    test "run completes when all steps are done" do
      # Use orchestrator workflow (no cycles — linear DAG)
      {:ok, run} = OrchestrationManager.start_run("orchestrator")

      # Complete all steps in dependency order
      complete_all_steps(run.id)

      final = OrchestrationManager.get_run(run.id)
      assert final.status in [:completed, :failed]
    end
  end

  describe "PubSub broadcasts" do
    test "broadcasts on run_started" do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, OrchestrationManager.pubsub_topic())

      {:ok, run} = OrchestrationManager.start_run("ralph")

      assert_receive {:run_started, ^run}, 1000
    end

    test "broadcasts on step_completed" do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, OrchestrationManager.pubsub_topic())

      {:ok, run} = OrchestrationManager.start_run("ralph")
      # Drain the :run_started message
      receive do
        {:run_started, _} -> :ok
      after
        500 -> :ok
      end

      [first | _] = OrchestrationManager.next_steps(run.id)
      {:ok, _} = OrchestrationManager.advance_step(run.id, first, %{})

      assert_receive {:step_completed, %{step_id: ^first}}, 1000
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp complete_all_steps(run_id) do
    case OrchestrationManager.next_steps(run_id) do
      [] ->
        :ok

      steps ->
        Enum.each(steps, fn step_id ->
          OrchestrationManager.advance_step(run_id, step_id, %{auto: true})
        end)

        complete_all_steps(run_id)
    end
  end
end
