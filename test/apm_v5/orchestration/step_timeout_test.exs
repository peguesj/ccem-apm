defmodule ApmV5.Orchestration.StepTimeoutTest do
  @moduledoc """
  Tests for :gen_statem step timeout policies in OrchestrationManager.

  A step with timeout_ms > 0 auto-fails the run if it does not complete
  within the given duration.

  CP-249 / wf-s6
  """
  use ExUnit.Case, async: false

  @moduletag :step_timeout

  alias ApmV5.Orchestration.OrchestrationManager

  setup do
    Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:orchestration")
    :ok
  end

  describe "step timeout_ms" do
    test "run fails after timeout_ms elapses if step not completed" do
      run_id = start_run_with_timeout(100)

      # Should still be running immediately after start
      {:ok, run} = OrchestrationManager.get_run(run_id)
      assert run.status == :running

      # Wait past the timeout
      Process.sleep(300)

      {:ok, timed_out} = OrchestrationManager.get_run(run_id)
      assert timed_out.status == :failed
      assert timed_out.metadata[:failure_reason] == {:timeout, "s1"}
    end

    test "step timeout emits :run_step_timeout PubSub event" do
      run_id = start_run_with_timeout(100)

      assert_receive {:run_step_timeout, ^run_id, "s1"}, 500
    end

    test "step timeout emits :run_failed PubSub event" do
      run_id = start_run_with_timeout(100)

      # Check for either run_failed or run_advanced events on "apm:orchestration"
      # (run_failed is broadcast on both topics)
      assert_receive {:run_failed, run}, 500
      assert run.id == run_id
    end

    test "cancelling a run before timeout fires does not leave stale timer messages" do
      run_id = start_run_with_timeout(500)
      :ok = OrchestrationManager.cancel_run(run_id)

      # Wait past timeout to verify no spurious :run_step_timeout fires
      Process.sleep(700)

      # If timeout fired despite cancellation, we'd receive the event
      refute_receive {:run_step_timeout, ^run_id, _step_id}, 100
    end

    test "run with no timeout_ms runs without auto-failing" do
      params = %{
        steps: [%{id: "s1", label: "Normal", type: :action}],
        edges: []
      }

      {:ok, run} = OrchestrationManager.start_run(params)

      Process.sleep(200)

      {:ok, still_running} = OrchestrationManager.get_run(run.id)
      assert still_running.status == :running

      # Cleanup
      OrchestrationManager.cancel_run(run.id)
    end

    test "advancing past a step cancels its timeout" do
      # Start a run where s1 has a 300ms timeout
      params = %{
        steps: [
          %{id: "s1", label: "Step with timeout", type: :action, timeout_ms: 300},
          %{id: "s2", label: "Next step", type: :action}
        ],
        edges: [%{source: "s1", target: "s2"}]
      }

      {:ok, run} = OrchestrationManager.start_run(params)

      # Advance past s1 before the timeout fires
      Process.sleep(50)
      {:ok, _} = OrchestrationManager.advance_step(run.id, "s2")

      # Wait past the original s1 timeout
      Process.sleep(400)

      # Run should NOT have failed
      {:ok, final} = OrchestrationManager.get_run(run.id)
      assert final.status == :running

      # No timeout event should have fired after we advanced
      refute_receive {:run_step_timeout, _run_id, "s1"}, 100

      # Cleanup
      OrchestrationManager.cancel_run(run.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_run_with_timeout(timeout_ms) do
    params = %{
      steps: [%{id: "s1", label: "Timed step", type: :action, timeout_ms: timeout_ms}],
      edges: []
    }

    {:ok, run} = OrchestrationManager.start_run(params)
    run.id
  end
end
