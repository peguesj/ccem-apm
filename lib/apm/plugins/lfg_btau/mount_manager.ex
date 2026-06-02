defmodule Apm.Plugins.LfgBtau.MountManager do
  @moduledoc """
  GenServer managing ref-counted mount/release lifecycle for the BTAU archival
  sparsebundle. Delegates actual hdiutil/shell work to btau_archive.sh via
  System.cmd (or an injected :mount_fn for tests).

  ## Mount flow
  - First caller: shell mount, store mount_point, issue lock token.
  - Subsequent callers: increment refcount, issue lock token (no shell call).
  - Owner process is monitored; death auto-decrements.

  ## Unmount flow
  - `release/1` decrements. When refcount reaches 0, schedules unmount via
    `Process.send_after` with TTL (default 600 s, configurable via app env
    `[:apm, :lfg_btau, :unmount_ttl_ms]`).
  - Scheduled unmount is cancelled if a new mount arrives before TTL fires.
  - `unmount_now/0` is an admin override; refuses when refcount > 0.
  """

  use GenServer
  require Logger

  @default_ttl_ms 600_000
  @btau_script "~/tools/@yj/lfg/lib/btau_archive.sh"
  @name __MODULE__

  ## ── Public API ────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec mount(String.t(), keyword()) ::
          {:ok, %{mount_point: String.t(), lock_token: reference(), ttl: integer()}}
          | {:error, term()}
  def mount(archive_id, opts \\ []) do
    GenServer.call(@name, {:mount, archive_id, opts})
  end

  @spec release(reference()) :: :ok
  def release(lock_token) do
    GenServer.call(@name, {:release, lock_token})
  end

  @spec status() :: %{
          mounted: boolean(),
          refcount: non_neg_integer(),
          mounted_at: DateTime.t() | nil,
          archive_id: String.t() | nil
        }
  def status do
    GenServer.call(@name, :status)
  end

  @spec unmount_now() :: :ok | {:error, :busy}
  def unmount_now do
    GenServer.call(@name, :unmount_now)
  end

  ## ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(opts) do
    mount_fn = Keyword.get(opts, :mount_fn, &default_mount_fn/1)
    unmount_fn = Keyword.get(opts, :unmount_fn, &default_unmount_fn/0)

    ttl_ms =
      Keyword.get_lazy(opts, :ttl_ms, fn ->
        Application.get_env(:apm, :lfg_btau_unmount_ttl_ms, @default_ttl_ms)
      end)

    state = %{
      archive_id: nil,
      mount_point: nil,
      refcount: 0,
      locks: %{},
      monitors: %{},
      mounted_at: nil,
      scheduled_unmount: nil,
      mount_fn: mount_fn,
      unmount_fn: unmount_fn,
      ttl_ms: ttl_ms
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:mount, archive_id, _opts}, {caller_pid, _}, state) do
    case do_mount(state, archive_id, caller_pid) do
      {:ok, token, new_state} ->
        result = %{
          mount_point: new_state.mount_point,
          lock_token: token,
          ttl: new_state.ttl_ms
        }

        {:reply, {:ok, result}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:release, lock_token}, _from, state) do
    {new_state, reply} = do_release(state, lock_token)
    {:reply, reply, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    result = %{
      mounted: state.mount_point != nil,
      refcount: state.refcount,
      mounted_at: state.mounted_at,
      archive_id: state.archive_id
    }

    {:reply, result, state}
  end

  @impl true
  def handle_call(:unmount_now, _from, %{refcount: rc} = state) when rc > 0 do
    {:reply, {:error, :busy}, state}
  end

  @impl true
  def handle_call(:unmount_now, _from, state) do
    new_state = cancel_scheduled_unmount(state)
    new_state = do_unmount(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:do_unmount, state) do
    # Only unmount if refcount is still 0 (guard against race)
    new_state =
      if state.refcount == 0 do
        do_unmount(%{state | scheduled_unmount: nil})
      else
        %{state | scheduled_unmount: nil}
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # Find the lock token owned by this monitor ref
    case Enum.find(state.monitors, fn {_token, mon_ref} -> mon_ref == ref end) do
      {token, _mon_ref} ->
        {new_state, _} = do_release(state, token)
        {:noreply, new_state}

      nil ->
        {:noreply, state}
    end
  end

  ## ── Private helpers ───────────────────────────────────────────────────────

  defp do_mount(%{mount_point: nil} = state, archive_id, caller_pid) do
    # First mount — call the shell script
    case state.mount_fn.(archive_id) do
      {:ok, mount_point} ->
        token = make_ref()
        mon_ref = Process.monitor(caller_pid)

        new_state = %{
          state
          | archive_id: archive_id,
            mount_point: mount_point,
            refcount: 1,
            locks: Map.put(state.locks, token, caller_pid),
            monitors: Map.put(state.monitors, token, mon_ref),
            mounted_at: DateTime.utc_now(),
            scheduled_unmount: nil
        }

        Logger.info("[MountManager] Mounted #{archive_id} at #{mount_point}")
        {:ok, token, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_mount(state, _archive_id, caller_pid) do
    # Already mounted — cancel any pending unmount, increment refcount
    state = cancel_scheduled_unmount(state)
    token = make_ref()
    mon_ref = Process.monitor(caller_pid)

    new_state = %{
      state
      | refcount: state.refcount + 1,
        locks: Map.put(state.locks, token, caller_pid),
        monitors: Map.put(state.monitors, token, mon_ref)
    }

    {:ok, token, new_state}
  end

  defp do_release(state, lock_token) do
    case Map.pop(state.locks, lock_token) do
      {nil, _} ->
        {state, :ok}

      {_pid, locks} ->
        {mon_ref, monitors} = Map.pop(state.monitors, lock_token)
        if mon_ref, do: Process.demonitor(mon_ref, [:flush])

        new_refcount = max(0, state.refcount - 1)

        new_state = %{state | refcount: new_refcount, locks: locks, monitors: monitors}

        new_state =
          if new_refcount == 0 do
            schedule_unmount(new_state)
          else
            new_state
          end

        {new_state, :ok}
    end
  end

  defp schedule_unmount(state) do
    state = cancel_scheduled_unmount(state)
    timer = Process.send_after(self(), :do_unmount, state.ttl_ms)
    Logger.debug("[MountManager] Scheduled unmount in #{state.ttl_ms}ms")
    %{state | scheduled_unmount: timer}
  end

  defp cancel_scheduled_unmount(%{scheduled_unmount: nil} = state), do: state

  defp cancel_scheduled_unmount(%{scheduled_unmount: timer} = state) do
    Process.cancel_timer(timer)
    %{state | scheduled_unmount: nil}
  end

  defp do_unmount(state) do
    if state.mount_point do
      state.unmount_fn.()
      Logger.info("[MountManager] Unmounted #{state.archive_id}")
    end

    %{
      state
      | archive_id: nil,
        mount_point: nil,
        refcount: 0,
        locks: %{},
        monitors: %{},
        mounted_at: nil,
        scheduled_unmount: nil
    }
  end

  ## ── Default shell fns ─────────────────────────────────────────────────────

  defp default_mount_fn(archive_id) do
    script = Path.expand(@btau_script)

    case System.cmd("bash", [script, "mount"], env: [{"BTAU_ARCHIVE_ID", archive_id}]) do
      {output, 0} ->
        mount_point =
          output
          |> String.trim()
          |> String.split("\n")
          |> List.last()

        {:ok, mount_point}

      {output, code} ->
        {:error, {code, String.trim(output)}}
    end
  end

  defp default_unmount_fn do
    script = Path.expand(@btau_script)
    System.cmd("bash", [script, "unmount"])
    :ok
  end
end
