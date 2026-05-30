defmodule Apm.Plugins.LfgBtau.MountManagerTest do
  use ExUnit.Case, async: true

  alias Apm.Plugins.LfgBtau.MountManager

  # Start an unnamed MountManager with injected stubs.
  defp start_manager(opts \\ []) do
    defaults = [
      name: nil,
      mount_fn: fn _archive_id -> {:ok, "/Volumes/BTAU"} end,
      unmount_fn: fn -> :ok end
    ]

    merged = Keyword.merge(defaults, opts)
    start_supervised!({MountManager, merged})
  end

  # Delegate helpers that accept a pid target.
  defp mount(pid, archive_id), do: GenServer.call(pid, {:mount, archive_id, []})
  defp release(pid, token), do: GenServer.call(pid, {:release, token})
  defp status(pid), do: GenServer.call(pid, :status)
  defp unmount_now(pid), do: GenServer.call(pid, :unmount_now)

  describe "first mount" do
    test "calls the mount_fn and returns mount_point + lock_token" do
      parent = self()

      mount_fn = fn archive_id ->
        send(parent, {:mount_called, archive_id})
        {:ok, "/Volumes/BTAU"}
      end

      pid = start_manager(mount_fn: mount_fn)

      assert {:ok, %{mount_point: "/Volumes/BTAU", lock_token: token, ttl: _}} =
               mount(pid, "btau-2024")

      assert is_reference(token)
      assert_received {:mount_called, "btau-2024"}
    end

    test "reflects mounted state in status/0" do
      pid = start_manager()
      {:ok, _} = mount(pid, "btau-2024")
      st = status(pid)
      assert st.mounted == true
      assert st.refcount == 1
      assert st.archive_id == "btau-2024"
      assert %DateTime{} = st.mounted_at
    end

    test "returns error when mount_fn fails" do
      pid = start_manager(mount_fn: fn _id -> {:error, :mount_failed} end)
      assert {:error, :mount_failed} = mount(pid, "bad-archive")
    end
  end

  describe "second mount (already mounted)" do
    test "does NOT call mount_fn again, only increments refcount" do
      call_count = :counters.new(1, [])

      mount_fn = fn _id ->
        :counters.add(call_count, 1, 1)
        {:ok, "/Volumes/BTAU"}
      end

      pid = start_manager(mount_fn: mount_fn)

      {:ok, _} = mount(pid, "btau-2024")
      {:ok, _} = mount(pid, "btau-2024")

      assert :counters.get(call_count, 1) == 1
      assert status(pid).refcount == 2
    end

    test "each mount returns a distinct lock token" do
      pid = start_manager()
      {:ok, %{lock_token: t1}} = mount(pid, "btau-2024")
      {:ok, %{lock_token: t2}} = mount(pid, "btau-2024")
      refute t1 == t2
    end
  end

  describe "release/1" do
    test "decrements refcount" do
      pid = start_manager()
      {:ok, %{lock_token: t1}} = mount(pid, "btau-2024")
      {:ok, %{lock_token: _t2}} = mount(pid, "btau-2024")
      assert status(pid).refcount == 2

      :ok = release(pid, t1)
      assert status(pid).refcount == 1
    end

    test "unknown token is a no-op" do
      pid = start_manager()
      {:ok, _} = mount(pid, "btau-2024")
      assert :ok = release(pid, make_ref())
    end

    test "refcount → 0 schedules unmount (timer fires)" do
      unmount_calls = :counters.new(1, [])

      unmount_fn = fn ->
        :counters.add(unmount_calls, 1, 1)
        :ok
      end

      # Inject short TTL via opts by overriding ttl_ms in state through init.
      # We pass :ttl_ms as a custom init opt.
      pid =
        start_supervised!(
          {MountManager,
           [
             name: nil,
             mount_fn: fn _id -> {:ok, "/Volumes/BTAU"} end,
             unmount_fn: unmount_fn,
             ttl_ms: 50
           ]}
        )

      {:ok, %{lock_token: token}} = mount(pid, "btau-2024")
      :ok = release(pid, token)

      # Refcount is 0 but still mounted (timer not fired yet)
      assert status(pid).refcount == 0

      # Wait for the timer to fire
      Process.sleep(200)
      assert :counters.get(unmount_calls, 1) == 1
      assert status(pid).mounted == false
    end
  end

  describe "owner process death" do
    test "auto-decrements refcount when holder dies" do
      pid = start_manager()

      # Spawn a long-lived process that mounts
      caller = self()

      owner =
        spawn(fn ->
          result = mount(pid, "btau-2024")
          send(caller, {:mounted, result})

          # Stay alive until told to stop
          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:mounted, {:ok, _}}, 1000
      assert status(pid).refcount == 1

      # Kill the owner — monitor should fire and decrement refcount
      Process.exit(owner, :kill)
      Process.sleep(50)
      assert status(pid).refcount == 0
    end
  end

  describe "unmount_now/0" do
    test "returns :busy when refcount > 0" do
      pid = start_manager()
      {:ok, _} = mount(pid, "btau-2024")
      assert {:error, :busy} = unmount_now(pid)
    end

    test "unmounts immediately when refcount == 0" do
      unmount_calls = :counters.new(1, [])

      unmount_fn = fn ->
        :counters.add(unmount_calls, 1, 1)
        :ok
      end

      pid = start_manager(unmount_fn: unmount_fn)
      {:ok, %{lock_token: token}} = mount(pid, "btau-2024")
      :ok = release(pid, token)

      assert :ok = unmount_now(pid)
      assert :counters.get(unmount_calls, 1) == 1
      assert status(pid).mounted == false
    end
  end
end
