defmodule Apm.A2A.FileLockRegistry do
  @moduledoc """
  ETS-backed pessimistic file lock registry for multi-agent workflows.

  Provides exclusive file-path locks with TTL-based expiry so that
  concurrent agents do not clobber each other's writes.

  ## Lock lifecycle

  1. An agent calls `acquire/3` to claim exclusive access to a file path.
     On success it receives a unique `lock_id`.
  2. While the lock is held, any other agent attempting `acquire/3` on
     the same path receives `{:error, :locked, info}` with holder details.
  3. The holder calls `release/1` to explicitly release, or the lock
     auto-expires after `ttl_ms` milliseconds (default 30 s).
  4. `release_all/1` is intended for agent-terminate cleanup so that
     an agent's locks are freed even if it crashes without calling
     `release/1` individually.

  ## ETS table

  `:file_locks` — `:public`, `:set`, keyed by `lock_id`.
  An index ETS table `:file_locks_by_path` (`:bag`) maps `file_path → lock_id`
  to enable O(1) conflict detection on `acquire/3`.

  ## PubSub

  - `{:lock_acquired, lock_id, file_path, agent_id}` — on `"a2a:locks"`
  - `{:lock_released, lock_id, file_path}` — on `"a2a:locks"`

  ## HTTP API

  - `GET  /api/v2/locks`         — list all active locks
  - `POST /api/v2/locks/acquire` — `{agent_id, file_path, ttl_ms}` → 201 / 409
  - `DELETE /api/v2/locks/:lock_id` — release lock
  """

  use GenServer

  require Logger

  @table :file_locks
  @index_table :file_locks_by_path
  @pubsub_topic "a2a:locks"
  @sweep_interval_ms 5_000
  @default_ttl_ms 30_000

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type lock_id :: String.t()

  @type lock_info :: %{
          lock_id: lock_id(),
          file_path: String.t(),
          holder: String.t(),
          expires_at: DateTime.t()
        }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Acquire a pessimistic lock on `file_path` for `agent_id`.

  Returns `{:ok, lock_id}` on success, or
  `{:error, :locked, %{holder, expires_at}}` if another agent holds the lock.

  `ttl_ms` defaults to #{@default_ttl_ms} ms (30 s).
  """
  @spec acquire(String.t(), String.t(), non_neg_integer()) ::
          {:ok, lock_id()} | {:error, :locked, map()}
  def acquire(agent_id, file_path, ttl_ms \\ @default_ttl_ms) do
    GenServer.call(__MODULE__, {:acquire, agent_id, file_path, ttl_ms})
  end

  @doc """
  Release a single lock by `lock_id`.

  Returns `:ok` whether or not the lock exists (idempotent).
  """
  @spec release(lock_id()) :: :ok
  def release(lock_id) do
    GenServer.call(__MODULE__, {:release, lock_id})
  end

  @doc """
  Release all locks held by `agent_id`.

  Intended for agent-terminate cleanup.
  """
  @spec release_all(String.t()) :: :ok
  def release_all(agent_id) do
    GenServer.call(__MODULE__, {:release_all, agent_id})
  end

  @doc "List all currently active (non-expired) locks."
  @spec list_locks() :: [lock_info()]
  def list_locks do
    case :ets.info(@table) do
      :undefined ->
        []

      _ ->
        now = DateTime.utc_now()

        :ets.tab2list(@table)
        |> Enum.map(&elem(&1, 1))
        |> Enum.filter(fn lock ->
          DateTime.compare(lock.expires_at, now) == :gt
        end)
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@index_table, [:named_table, :public, :bag])
    schedule_sweep()
    Logger.info("[FileLockRegistry] Started — sweep every #{@sweep_interval_ms}ms")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:acquire, agent_id, file_path, ttl_ms}, _from, state) do
    now = DateTime.utc_now()

    # Check for an existing, non-expired lock on this path
    case find_active_lock(file_path, now) do
      {:found, existing} ->
        {:reply, {:error, :locked, %{holder: existing.holder, expires_at: existing.expires_at}},
         state}

      :none ->
        lock_id = generate_lock_id()

        expires_at =
          now
          |> DateTime.add(ttl_ms, :millisecond)

        lock = %{
          lock_id: lock_id,
          file_path: file_path,
          holder: agent_id,
          expires_at: expires_at
        }

        :ets.insert(@table, {lock_id, lock})
        :ets.insert(@index_table, {file_path, lock_id})

        Phoenix.PubSub.broadcast(Apm.PubSub, @pubsub_topic, {
          :lock_acquired,
          lock_id,
          file_path,
          agent_id
        })

        Logger.debug("[FileLockRegistry] Acquired lock #{lock_id} on #{file_path} by #{agent_id}")
        {:reply, {:ok, lock_id}, state}
    end
  end

  def handle_call({:release, lock_id}, _from, state) do
    do_release(lock_id)
    {:reply, :ok, state}
  end

  def handle_call({:release_all, agent_id}, _from, state) do
    case :ets.info(@table) do
      :undefined ->
        :ok

      _ ->
        :ets.tab2list(@table)
        |> Enum.each(fn {lock_id, lock} ->
          if lock.holder == agent_id do
            do_release(lock_id)
          end
        end)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_expired()
    schedule_sweep()
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp find_active_lock(file_path, now) do
    case :ets.lookup(@index_table, file_path) do
      [] ->
        :none

      entries ->
        lock_id =
          entries
          |> Enum.map(fn {_path, lid} -> lid end)
          |> Enum.find(fn lid ->
            case :ets.lookup(@table, lid) do
              [{^lid, lock}] ->
                DateTime.compare(lock.expires_at, now) == :gt

              [] ->
                false
            end
          end)

        case lock_id do
          nil ->
            :none

          lid ->
            [{^lid, lock}] = :ets.lookup(@table, lid)
            {:found, lock}
        end
    end
  end

  defp do_release(lock_id) do
    case :ets.lookup(@table, lock_id) do
      [{^lock_id, lock}] ->
        :ets.delete(@table, lock_id)
        :ets.delete_object(@index_table, {lock.file_path, lock_id})

        Phoenix.PubSub.broadcast(Apm.PubSub, @pubsub_topic, {
          :lock_released,
          lock_id,
          lock.file_path
        })

        Logger.debug("[FileLockRegistry] Released lock #{lock_id} on #{lock.file_path}")

      [] ->
        :ok
    end
  end

  defp sweep_expired do
    case :ets.info(@table) do
      :undefined ->
        :ok

      _ ->
        now = DateTime.utc_now()

        :ets.tab2list(@table)
        |> Enum.each(fn {lock_id, lock} ->
          if DateTime.compare(lock.expires_at, now) != :gt do
            Logger.debug(
              "[FileLockRegistry] Sweeping expired lock #{lock_id} on #{lock.file_path}"
            )

            do_release(lock_id)
          end
        end)
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp generate_lock_id do
    "lock_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
