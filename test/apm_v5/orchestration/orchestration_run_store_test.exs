defmodule ApmV5.Orchestration.OrchestrationRunStoreTest do
  use ExUnit.Case, async: false

  @moduletag :orchestration

  alias ApmV5.Orchestration.OrchestrationRunStore
  alias ApmV5.Orchestration.OrchestrationManager

  setup do
    # Ensure GenServers are running
    for mod <- [OrchestrationManager, OrchestrationRunStore] do
      case Process.whereis(mod) do
        nil -> {:ok, _} = mod.start_link()
        _pid -> :ok
      end
    end

    # Clear ETS tables
    :ets.delete_all_objects(:orchestration_runs)
    :ets.delete_all_objects(:orchestration_run_history)
    :ok
  end

  describe "save_run/1" do
    test "archives a run" do
      run = make_run("test-run-1", "ralph", :completed)
      OrchestrationRunStore.save_run(run)
      # Give the cast time to process
      Process.sleep(50)
      assert OrchestrationRunStore.get_run("test-run-1") != nil
    end

    test "adds archived_at timestamp" do
      run = make_run("test-run-2", "ralph", :completed)
      OrchestrationRunStore.save_run(run)
      Process.sleep(50)
      archived = OrchestrationRunStore.get_run("test-run-2")
      assert archived.archived_at != nil
    end
  end

  describe "list_runs/1" do
    test "lists runs with default limit" do
      for i <- 1..5 do
        OrchestrationRunStore.save_run(make_run("run-#{i}", "ralph", :completed))
      end

      Process.sleep(100)
      runs = OrchestrationRunStore.list_runs()
      assert length(runs) == 5
    end

    test "filters by workflow_id" do
      OrchestrationRunStore.save_run(make_run("run-a", "ralph", :completed))
      OrchestrationRunStore.save_run(make_run("run-b", "upm", :completed))
      Process.sleep(100)

      runs = OrchestrationRunStore.list_runs(workflow_id: "ralph")
      assert length(runs) == 1
      assert hd(runs).workflow_id == "ralph"
    end

    test "filters by status" do
      OrchestrationRunStore.save_run(make_run("run-ok", "ralph", :completed))
      OrchestrationRunStore.save_run(make_run("run-fail", "ralph", :failed))
      Process.sleep(100)

      runs = OrchestrationRunStore.list_runs(status: :completed)
      assert length(runs) == 1
      assert hd(runs).status == :completed
    end

    test "respects limit" do
      for i <- 1..10 do
        OrchestrationRunStore.save_run(make_run("run-lim-#{i}", "ralph", :completed))
      end

      Process.sleep(100)
      runs = OrchestrationRunStore.list_runs(limit: 3)
      assert length(runs) == 3
    end
  end

  describe "get_run/1" do
    test "returns nil for non-existent run" do
      assert OrchestrationRunStore.get_run("does-not-exist") == nil
    end
  end

  describe "replay_run/2" do
    test "creates a new run from historical config" do
      # Start and complete a run to archive it
      {:ok, original} = OrchestrationManager.start_run("ralph")

      # Manually archive it
      OrchestrationRunStore.save_run(%{original | status: :completed})
      Process.sleep(50)

      # Replay
      {:ok, replayed} = OrchestrationRunStore.replay_run(original.id)
      assert replayed.id != original.id
      assert replayed.workflow_id == "ralph"
      assert replayed.status == :pending
    end

    test "returns error for non-existent historical run" do
      assert {:error, {:run_not_found, "fake"}} = OrchestrationRunStore.replay_run("fake")
    end
  end

  describe "count/0" do
    test "returns the count of stored runs" do
      assert OrchestrationRunStore.count() == 0

      OrchestrationRunStore.save_run(make_run("cnt-1", "ralph", :completed))
      Process.sleep(50)
      assert OrchestrationRunStore.count() == 1
    end
  end

  describe "LRU eviction" do
    test "enforces max history of 100" do
      for i <- 1..105 do
        OrchestrationRunStore.save_run(make_run("evict-#{i}", "ralph", :completed))
      end

      Process.sleep(200)
      assert OrchestrationRunStore.count() <= 100
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp make_run(id, workflow_id, status) do
    %{
      id: id,
      workflow_id: workflow_id,
      status: status,
      steps: %{},
      edges: [],
      current_wave: 0,
      params: %{},
      dry_run: false,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end
end
