defmodule ApmV5.JobQueueTest do
  use ExUnit.Case, async: false

  alias ApmV5.JobQueue

  setup do
    # Stop any existing instance and start fresh for each test
    case Process.whereis(JobQueue) do
      nil -> :ok
      pid -> GenServer.stop(pid)
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
    # Saturate the queue first
    JobQueue.enqueue(fn -> Process.sleep(100); send(parent, {:done, :a}) end)
    JobQueue.enqueue(fn -> Process.sleep(100); send(parent, {:done, :b}) end)
    # These are queued
    JobQueue.enqueue(fn -> send(parent, {:done, :low}) end, priority: :low)
    JobQueue.enqueue(fn -> send(parent, {:done, :critical}) end, priority: :critical)

    # critical runs before low
    messages =
      for _ <- 1..4 do
        assert_receive {:done, v}, 2_000
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
