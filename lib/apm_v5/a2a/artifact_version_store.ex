defmodule ApmV5.A2A.ArtifactVersionStore do
  @moduledoc """
  ETS-backed GenServer providing optimistic concurrency control (compare-and-swap)
  for shared artifacts in multi-agent workflows.

  ## Purpose

  When multiple agents may edit the same artifact (e.g., a skill file, a
  shared document, a config entry), concurrent writes can produce silent
  data loss.  `ArtifactVersionStore` provides a lightweight CAS primitive:
  each agent reads the current version, increments via `cas/3`, and on
  conflict retries with the latest version.

  ## ETS Table

  `:artifact_versions` — `:protected`, `:set`, keyed by `artifact_key`
  (any term, typically a string), value: `{version :: non_neg_integer()}`.

  ## PubSub

  Successful CAS broadcasts `{:artifact_updated, key, new_version, agent_id}`
  on topic `"a2a:artifacts"` so downstream watchers (e.g., dashboard LiveViews
  or dependent agents) can react without polling.

  ## Concurrency Safety

  The CAS operation is performed inside a `GenServer.call/2` so all mutations
  are serialised through the GenServer process.  ETS reads via `get_version/1`
  are direct (no GenServer round-trip) — safe because the table is `:protected`
  and only the GenServer writes.

  ## HTTP API

  - `GET  /api/v2/a2a/artifacts/:key/version` — returns `{version: N}`
  - `POST /api/v2/a2a/artifacts/:key/cas`     — `{expected: N, agent_id: "..."}`
    → `{ok: true, version: M}` or `{ok: false, conflict: true, current_version: M}`
  """

  use GenServer

  require Logger

  @table :artifact_versions
  @pubsub_topic "a2a:artifacts"

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Return the current version for `key`. Defaults to `0` if unseen.

  This is a direct ETS read — no GenServer round-trip.
  """
  @spec get_version(term()) :: non_neg_integer()
  def get_version(key) do
    case :ets.lookup(@table, key) do
      [{^key, version}] -> version
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc """
  Compare-and-swap.

  If the current version of `key` equals `expected_version`, atomically
  increments the version and returns `{:ok, new_version}`.

  If the current version differs from `expected_version` — indicating a
  concurrent update — returns `{:error, :conflict, current_version}`.

  A successful CAS broadcasts `{:artifact_updated, key, new_version, agent_id}`
  on the `"a2a:artifacts"` PubSub topic.

  ## Examples

      ArtifactVersionStore.cas("skill:foo", 0, "agent-a")
      # => {:ok, 1}

      ArtifactVersionStore.cas("skill:foo", 0, "agent-b")
      # => {:error, :conflict, 1}  (concurrent update, current is now 1)
  """
  @spec cas(term(), non_neg_integer(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, :conflict, non_neg_integer()}
  def cas(key, expected_version, agent_id) do
    GenServer.call(__MODULE__, {:cas, key, expected_version, agent_id})
  end

  @doc """
  Forcefully set the version for `key` to `version`.

  Admin escape hatch — bypasses CAS optimistic lock.  Use for
  migrations or manual corrections only.
  """
  @spec force_set(term(), non_neg_integer()) :: :ok
  def force_set(key, version) do
    GenServer.call(__MODULE__, {:force_set, key, version})
  end

  @doc """
  Reset `key` to version 0 (or remove it entirely).

  Intended for test teardown.
  """
  @spec reset(term()) :: :ok
  def reset(key) do
    GenServer.call(__MODULE__, {:reset, key})
  end

  @doc "List all tracked artifact keys and their current versions."
  @spec list_all() :: [{term(), non_neg_integer()}]
  def list_all do
    case :ets.info(@table) do
      :undefined -> []
      _ -> :ets.tab2list(@table)
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    Logger.info("[ArtifactVersionStore] Started — ETS table #{@table} ready")
    {:ok, %{cas_count: 0, conflict_count: 0}}
  end

  @impl true
  def handle_call({:cas, key, expected_version, agent_id}, _from, state) do
    current = get_version(key)

    if current == expected_version do
      new_version = current + 1
      :ets.insert(@table, {key, new_version})

      Phoenix.PubSub.broadcast(ApmV5.PubSub, @pubsub_topic, {
        :artifact_updated,
        key,
        new_version,
        agent_id
      })

      Logger.debug(
        "[ArtifactVersionStore] CAS #{inspect(key)}: #{current} → #{new_version} by #{agent_id}"
      )

      {:reply, {:ok, new_version}, %{state | cas_count: state.cas_count + 1}}
    else
      Logger.debug(
        "[ArtifactVersionStore] CAS conflict #{inspect(key)}: expected=#{expected_version} actual=#{current} by #{agent_id}"
      )

      {:reply, {:error, :conflict, current},
       %{state | conflict_count: state.conflict_count + 1}}
    end
  end

  @impl true
  def handle_call({:force_set, key, version}, _from, state) do
    :ets.insert(@table, {key, version})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:reset, key}, _from, state) do
    :ets.delete(@table, key)
    {:reply, :ok, state}
  end
end
