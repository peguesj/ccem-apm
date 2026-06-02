defmodule Apm.A2A.FileLockRegistryTest do
  @moduledoc """
  Tests for Apm.A2A.FileLockRegistry — pessimistic file lock with TTL.

  CP-258 / coord-c2
  """
  use ExUnit.Case, async: false

  @moduletag :file_lock_registry

  alias Apm.A2A.FileLockRegistry

  # Start an isolated registry under a unique name for each test so tests
  # do not share ETS state.  The application-level registry is started by
  # the supervision tree; we start a second one here for test isolation.
  setup do
    # Subscribe to PubSub to verify broadcasts
    Phoenix.PubSub.subscribe(Apm.PubSub, "a2a:locks")

    # Release all locks before each test to avoid state bleed from
    # the application-supervised registry.
    FileLockRegistry.release_all("test-agent-a")
    FileLockRegistry.release_all("test-agent-b")
    FileLockRegistry.release_all("test-agent-cleanup")

    :ok
  end

  describe "acquire/3" do
    test "first agent acquires successfully and gets a lock_id" do
      path = unique_path("acquire-first")
      assert {:ok, lock_id} = FileLockRegistry.acquire("test-agent-a", path)
      assert is_binary(lock_id)
      assert String.starts_with?(lock_id, "lock_")

      # Cleanup
      FileLockRegistry.release(lock_id)
    end

    test "second agent on same path gets {:error, :locked, info}" do
      path = unique_path("acquire-conflict")
      assert {:ok, lock_id} = FileLockRegistry.acquire("test-agent-a", path)

      result = FileLockRegistry.acquire("test-agent-b", path)
      assert {:error, :locked, info} = result
      assert info.holder == "test-agent-a"
      assert %DateTime{} = info.expires_at

      # Cleanup
      FileLockRegistry.release(lock_id)
    end

    test "same agent can hold locks on different paths simultaneously" do
      path1 = unique_path("multi-path-1")
      path2 = unique_path("multi-path-2")

      assert {:ok, lock_id1} = FileLockRegistry.acquire("test-agent-a", path1)
      assert {:ok, lock_id2} = FileLockRegistry.acquire("test-agent-a", path2)

      assert lock_id1 != lock_id2

      FileLockRegistry.release(lock_id1)
      FileLockRegistry.release(lock_id2)
    end

    test "broadcasts :lock_acquired on a2a:locks" do
      path = unique_path("broadcast-acquire")
      assert {:ok, lock_id} = FileLockRegistry.acquire("test-agent-a", path)

      assert_receive {:lock_acquired, ^lock_id, ^path, "test-agent-a"}, 500

      FileLockRegistry.release(lock_id)
    end
  end

  describe "release/1" do
    test "releases a held lock and allows re-acquisition" do
      path = unique_path("release-reacquire")
      assert {:ok, lock_id} = FileLockRegistry.acquire("test-agent-a", path)

      assert :ok = FileLockRegistry.release(lock_id)

      # Another agent can now acquire it
      assert {:ok, _new_lock_id} = FileLockRegistry.acquire("test-agent-b", path)
      FileLockRegistry.release_all("test-agent-b")
    end

    test "release/1 is idempotent — releasing unknown lock_id returns :ok" do
      assert :ok = FileLockRegistry.release("lock_nonexistent_00000000")
    end

    test "broadcasts :lock_released on a2a:locks" do
      path = unique_path("broadcast-release")
      assert {:ok, lock_id} = FileLockRegistry.acquire("test-agent-a", path)
      # Drain the acquire broadcast
      assert_receive {:lock_acquired, _, _, _}, 500

      FileLockRegistry.release(lock_id)
      assert_receive {:lock_released, ^lock_id, ^path}, 500
    end
  end

  describe "release_all/1" do
    test "releases all locks held by the agent" do
      path1 = unique_path("release-all-1")
      path2 = unique_path("release-all-2")
      assert {:ok, _} = FileLockRegistry.acquire("test-agent-cleanup", path1)
      assert {:ok, _} = FileLockRegistry.acquire("test-agent-cleanup", path2)

      assert :ok = FileLockRegistry.release_all("test-agent-cleanup")

      # Both paths should now be acquirable by another agent
      assert {:ok, l1} = FileLockRegistry.acquire("test-agent-b", path1)
      assert {:ok, l2} = FileLockRegistry.acquire("test-agent-b", path2)

      FileLockRegistry.release(l1)
      FileLockRegistry.release(l2)
    end

    test "release_all/1 is a no-op for an agent with no locks" do
      assert :ok = FileLockRegistry.release_all("agent-with-no-locks")
    end
  end

  describe "TTL expiry" do
    test "lock auto-expires and path can be re-acquired after ttl elapses" do
      path = unique_path("ttl-expiry")
      # Acquire with very short TTL
      assert {:ok, _lock_id} = FileLockRegistry.acquire("test-agent-a", path, 100)

      # Confirm it's locked
      assert {:error, :locked, _} = FileLockRegistry.acquire("test-agent-b", path)

      # Wait for TTL + a buffer
      Process.sleep(250)

      # Should now be acquirable — the sweep or find_active_lock skips expired locks
      assert {:ok, new_lock_id} = FileLockRegistry.acquire("test-agent-b", path)
      FileLockRegistry.release(new_lock_id)
    end
  end

  describe "list_locks/0" do
    test "returns all active locks" do
      path = unique_path("list-active")
      assert {:ok, lock_id} = FileLockRegistry.acquire("test-agent-a", path)

      locks = FileLockRegistry.list_locks()
      lock_ids = Enum.map(locks, & &1.lock_id)
      assert lock_id in lock_ids

      FileLockRegistry.release(lock_id)
    end

    test "does not return expired locks" do
      path = unique_path("list-expired")
      assert {:ok, lock_id} = FileLockRegistry.acquire("test-agent-a", path, 50)

      Process.sleep(200)

      locks = FileLockRegistry.list_locks()
      lock_ids = Enum.map(locks, & &1.lock_id)
      refute lock_id in lock_ids
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_path(suffix) do
    "/tmp/test-#{:erlang.unique_integer([:positive])}-#{suffix}.ex"
  end
end
