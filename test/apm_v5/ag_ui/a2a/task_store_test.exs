defmodule ApmV5.AgUi.A2A.TaskStoreTest do
  @moduledoc """
  Basic acceptance tests for the A2A v0.3.0 task lifecycle state machine.

  AC (coord-b1):
  - create_task/3 → :submitted
  - transition/2 :submitted → :working succeeds
  - transition/2 :completed → :working returns {:error, :terminal_state}
  """
  use ExUnit.Case, async: false

  alias ApmV5.AgUi.A2A.TaskStore

  setup do
    # Ensure TaskStore is running; start standalone if needed.
    case GenServer.whereis(TaskStore) do
      nil -> {:ok, _} = TaskStore.start_link([])
      _pid -> :ok
    end

    :ok
  end

  describe "create_task/3" do
    test "creates task in :submitted state" do
      {:ok, task} = TaskStore.create_task("agent-1", "env-001")

      assert task.status == :submitted
      assert task.agent_id == "agent-1"
      assert "env-001" in task.envelope_ids
      assert is_binary(task.id)
      assert %DateTime{} = task.created_at
      assert %DateTime{} = task.updated_at
    end

    test "get_task/1 returns the created task" do
      {:ok, task} = TaskStore.create_task("agent-2", "env-002")
      fetched = TaskStore.get_task(task.id)

      assert fetched.id == task.id
      assert fetched.status == :submitted
    end
  end

  describe "transition/2" do
    test ":submitted → :working succeeds" do
      {:ok, task} = TaskStore.create_task("agent-3", "env-003")

      assert {:ok, updated} = TaskStore.transition(task.id, :working)
      assert updated.status == :working
    end

    test "terminal :completed → :working returns {:error, :terminal_state}" do
      {:ok, task} = TaskStore.create_task("agent-4", "env-004")
      {:ok, _} = TaskStore.transition(task.id, :working)
      {:ok, _} = TaskStore.transition(task.id, :completed)

      assert {:error, :terminal_state} = TaskStore.transition(task.id, :working)
    end

    test "invalid transition returns {:error, :invalid_transition}" do
      {:ok, task} = TaskStore.create_task("agent-5", "env-005")
      # :submitted cannot go directly to :completed
      assert {:error, :invalid_transition} = TaskStore.transition(task.id, :completed)
    end

    test "unknown task_id returns {:error, :not_found}" do
      assert {:error, :not_found} = TaskStore.transition("nonexistent-id", :working)
    end

    test "list_by_status/1 filters correctly" do
      {:ok, t1} = TaskStore.create_task("agent-6", "env-006")
      {:ok, _t2} = TaskStore.create_task("agent-7", "env-007")
      TaskStore.transition(t1.id, :working)

      working = TaskStore.list_by_status(:working)
      assert Enum.any?(working, fn t -> t.id == t1.id end)
    end
  end
end
