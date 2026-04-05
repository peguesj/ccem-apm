defmodule ApmV5.ConcurrencyLayerTest do
  use ExUnit.Case, async: true

  alias ApmV5.ConcurrencyLayer

  setup do
    # TaskSupervisor is started via application supervision tree in test env
    :ok
  end

  describe "fire_and_forget/2" do
    test "dispatches work and returns :ok immediately" do
      parent = self()
      assert :ok = ConcurrencyLayer.fire_and_forget(fn -> send(parent, :done) end, :test_fire)
      assert_receive :done, 1_000
    end

    test "swallows exceptions" do
      assert :ok =
               ConcurrencyLayer.fire_and_forget(
                 fn -> raise "boom" end,
                 :test_crash
               )

      # Caller not affected
      Process.sleep(50)
      assert Process.alive?(self())
    end
  end

  describe "bounded_async_stream/3" do
    test "runs items concurrently" do
      results =
        1..5
        |> ConcurrencyLayer.bounded_async_stream(fn i -> i * 2 end, max_concurrency: 3)
        |> Enum.map(fn {:ok, v} -> v end)
        |> Enum.sort()

      assert results == [2, 4, 6, 8, 10]
    end
  end

  describe "supervised_await/3" do
    test "returns ok result" do
      assert {:ok, 42} = ConcurrencyLayer.supervised_await(fn -> 42 end, :test_await)
    end

    test "returns error on timeout" do
      assert {:error, :timeout} =
               ConcurrencyLayer.supervised_await(
                 fn -> Process.sleep(200) end,
                 :test_timeout,
                 50
               )
    end
  end
end
