defmodule ApmV5.JobQueueTest do
  use ExUnit.Case, async: false

  alias ApmV5.JobQueue

  setup do
    # Stop any existing instance and wait for name deregistration.
    case Process.whereis(JobQueue) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        GenServer.stop(pid, :normal, 1_000)

        receive do
          {:DOWN, ^ref, :process, _, _} -> :ok
        after
          1_000 -> :ok
        end
    end

    # Ensure the Task.Supervisor backing the JobQueue is alive (app may have
    # stopped it when previous test crashed). Start only if missing.
    unless Process.whereis(ApmV5.ConcurrencyLayer.TaskSupervisor) do
      {:ok, _} = Task.Supervisor.start_link(name: ApmV5.ConcurrencyLayer.TaskSupervisor)
    end

    {:ok, _pid} =
      JobQueue.start_link(max_concurrent: 2, max_attempts: 2, base_backoff_ms: 50)

    :ok
  end

  test "enqueue returns {:ok, ref}" do
    assert {:ok, ref} = JobQueue.enqueue(fn -> :ok end)
    assert is_reference(ref)
  end

  test "runs queued jobs" do
    parent = self()

    for i <- 1..5 do
      JobQueue.enqueue(fn -> send(parent, {:done, i}) end, label: :test_job)
    end

    for i <- 1..5, do: assert_receive({:done, ^i}, 2_000)
  end

  test "respects priority ordering" do
    parent = self()
    # Saturate the queue with two long-running jobs so subsequent enqueues are queued.
    JobQueue.enqueue(fn -> Process.sleep(200); send(parent, {:done, :a}) end)
    JobQueue.enqueue(fn -> Process.sleep(200); send(parent, {:done, :b}) end)
    # Let the dispatcher tick and pick them up.
    Process.sleep(100)
    # Both slots now busy; these two are queued by priority.
    JobQueue.enqueue(fn -> send(parent, {:done, :low}) end, priority: :low)
    JobQueue.enqueue(fn -> send(parent, {:done, :critical}) end, priority: :critical)

    messages =
      for _ <- 1..4 do
        assert_receive {:done, v}, 3_000
        v
      end

    critical_idx = Enum.find_index(messages, &(&1 == :critical))
    low_idx = Enum.find_index(messages, &(&1 == :low))
    assert critical_idx < low_idx
  end

  test "retries failing jobs up to max_attempts" do
    parent = self()
    counter = :counters.new(1, [])

    JobQueue.enqueue(
      fn ->
        n = :counters.get(counter, 1) + 1
        :counters.add(counter, 1, 1)
        send(parent, {:attempt, n})
        raise "always fails"
      end,
      label: :retry_test
    )

    assert_receive {:attempt, 1}, 1_000
    assert_receive {:attempt, 2}, 2_000
    refute_receive {:attempt, 3}, 500
  end

  test "stats reports running/queued/completed" do
    JobQueue.enqueue(fn -> :ok end)
    JobQueue.enqueue(fn -> :ok end)
    Process.sleep(200)
    stats = JobQueue.stats()
    assert stats.completed >= 2
  end
end
