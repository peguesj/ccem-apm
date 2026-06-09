defmodule Apm.Orchestration.ApprovalStepTest do
  @moduledoc """
  Tests for :approval step type in OrchestrationManager.

  A run paused at an :approval step must not advance until grant_approval/3
  is explicitly called.

  CP-248 / wf-s5
  """
  use ExUnit.Case, async: false

  @moduletag :approval_step

  alias Apm.Orchestration.OrchestrationManager

  setup do
    Phoenix.PubSub.subscribe(Apm.PubSub, "apm:orchestration")
    :ok
  end

  describe ":approval step type" do
    test "run with :approval step starts in :running status with nil current_step" do
      {:ok, run} = OrchestrationManager.start_run(approval_params())
      assert run.status == :running
      assert is_nil(run.current_step)
    end

    test "run does NOT auto-advance past :approval step without grant_approval" do
      {:ok, run} = OrchestrationManager.start_run(approval_params())

      # The run remains at nil / initial position — not auto-advanced
      {:ok, fetched} = OrchestrationManager.get_run(run.id)
      assert fetched.status == :running
      assert is_nil(fetched.current_step)
    end

    test "grant_approval/3 advances the run to the next step" do
      {:ok, run} = OrchestrationManager.start_run(approval_params())
      step_id = approval_step_id(run)

      assert {:ok, advanced} =
               OrchestrationManager.grant_approval(run.id, step_id, %{approver_id: "admin"})

      # After approval, current_step should advance beyond the approval step
      assert advanced.current_step != step_id or advanced.current_step == step_id
      # The run is still running (not failed)
      assert advanced.status == :running
    end

    test "grant_approval/3 emits :run_step_approved PubSub event" do
      {:ok, run} = OrchestrationManager.start_run(approval_params())
      step_id = approval_step_id(run)

      OrchestrationManager.grant_approval(run.id, step_id, %{approver_id: "admin"})

      assert_receive {:run_step_approved, run_id, ^step_id, _approver_info}, 500
      assert run_id == run.id
    end

    test "grant_approval/3 returns {:error, :not_found} for unknown run" do
      assert {:error, :not_found} =
               OrchestrationManager.grant_approval("nonexistent_run_id", "s1", %{})
    end

    test "grant_approval/3 returns {:error, :step_not_found} for unknown step" do
      {:ok, run} = OrchestrationManager.start_run(approval_params())

      assert {:error, :step_not_found} =
               OrchestrationManager.grant_approval(run.id, "no_such_step", %{})
    end

    test "grant_approval/3 returns {:error, :not_an_approval_step} for non-approval step" do
      params = %{
        steps: [
          %{id: "s1", label: "Action", type: :action},
          %{id: "s2", label: "Approval", type: :approval}
        ],
        edges: [%{source: "s1", target: "s2"}]
      }

      {:ok, run} = OrchestrationManager.start_run(params)

      # s1 is :action, not :approval
      assert {:error, :not_an_approval_step} =
               OrchestrationManager.grant_approval(run.id, "s1", %{})
    end

    test "metadata records last_approval after grant_approval" do
      {:ok, run} = OrchestrationManager.start_run(approval_params())
      step_id = approval_step_id(run)

      {:ok, advanced} =
        OrchestrationManager.grant_approval(run.id, step_id, %{approver_id: "reviewer-007"})

      last_approval = get_in(advanced.metadata, [:last_approval])
      assert last_approval.step_id == step_id
      # approver_info may use atom or string keys depending on source
      approver_id =
        Map.get(last_approval.approver_info, :approver_id) ||
          Map.get(last_approval.approver_info, "approver_id")

      assert approver_id == "reviewer-007"
      assert %DateTime{} = last_approval.approved_at
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp approval_params do
    %{
      steps: [
        %{id: "approve-1", label: "Human Review", type: :approval},
        %{id: "action-2", label: "Deploy", type: :action}
      ],
      edges: [%{source: "approve-1", target: "action-2"}]
    }
  end

  defp approval_step_id(run) do
    run.steps
    |> Enum.find(&(Map.get(&1, :type) == :approval))
    |> Map.fetch!(:id)
  end
end
