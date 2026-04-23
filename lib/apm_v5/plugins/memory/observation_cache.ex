defmodule ApmV5.Plugins.Memory.ObservationCache do
  @moduledoc """
  ETS-backed GenServer cache for memory plugin observations.

  Observations are stored with an inserted-at monotonic timestamp and
  automatically expire after `@ttl_ms` (5 minutes). A periodic sweep
  removes stale entries every 60 seconds. When the table exceeds
  `@max_entries`, the oldest entry is evicted before inserting a new one
  (LRU by insertion time).

  ## ETS Schema

      {id, observation_map, inserted_at_unix_ms}

  where `inserted_at_unix_ms` is `System.monotonic_time(:millisecond)` at
  insert time.

  ## PubSub

  After `put/2` or `refresh/1` the cache broadcasts to the `"apm:memory"`
  topic:

      {:observations_updated, count}

  ## Usage

      ObservationCache.put("obs-1", %{narrative: "agent started", ...})
      ObservationCache.get("obs-1")
      ObservationCache.list(limit: 20, offset: 0)
      ObservationCache.search("agent")
      ObservationCache.refresh([%{id: "obs-1", narrative: "..."}])
      ObservationCache.stats()
      ObservationCache.clear()
  """

  use GenServer

  require Logger

  @table :observation_cache
  @max_entries 500
  @ttl_ms 300_000
  @sweep_interval_ms 60_000
  @pubsub_topic "apm:memory"

  # ── Public API ────────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store a single observation map under `id`.

  If the table is at capacity the oldest entry is evicted first.
  Broadcasts `{:observations_updated, count}` on `"apm:memory"` after insert.
  """
  @spec put(String.t() | integer(), map()) :: :ok
  def put(id, observation) when is_map(observation) do
    str_id = to_string(id)
    now = System.monotonic_time(:millisecond)
    maybe_evict_oldest()
    :ets.insert(@table, {str_id, observation, now})
    broadcast_update()
    :ok
  end

  @doc """
  Fetch an observation by `id`. Returns `nil` if not found or expired.
  """
  @spec get(String.t() | integer()) :: map() | nil
  def get(id) do
    str_id = to_string(id)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, str_id) do
      [{^str_id, observation, inserted_at}] when now - inserted_at <= @ttl_ms ->
        observation

      [{^str_id, _observation, _inserted_at}] ->
        :ets.delete(@table, str_id)
        nil

      [] ->
        nil
    end
  end

  @doc """
  List all non-expired observations.

  Accepts `limit:` and `offset:` options (both default to no restriction).
  Returns a list of observation maps in insertion order (oldest first).
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    now = System.monotonic_time(:millisecond)
    limit = Keyword.get(opts, :limit, :infinity)
    offset = Keyword.get(opts, :offset, 0)

    :ets.tab2list(@table)
    |> Enum.filter(fn {_id, _obs, inserted_at} -> now - inserted_at <= @ttl_ms end)
    |> Enum.sort_by(fn {_id, _obs, inserted_at} -> inserted_at end)
    |> Enum.drop(offset)
    |> apply_limit(limit)
    |> Enum.map(fn {_id, obs, _inserted_at} -> obs end)
  end

  @doc """
  Simple substring search across observation `narrative` fields (case-insensitive).

  Returns a list of matching observation maps.
  """
  @spec search(String.t()) :: [map()]
  def search(query) when is_binary(query) do
    now = System.monotonic_time(:millisecond)
    downcased = String.downcase(query)

    :ets.tab2list(@table)
    |> Enum.filter(fn {_id, obs, inserted_at} ->
      now - inserted_at <= @ttl_ms and narrative_matches?(obs, downcased)
    end)
    |> Enum.map(fn {_id, obs, _inserted_at} -> obs end)
  end

  @doc """
  Bulk-insert a list of observation maps, replacing any existing entry with the
  same id. Each observation must have an `"id"` or `:id` key.

  Broadcasts `{:observations_updated, count}` after all inserts.
  """
  @spec refresh([map()]) :: :ok
  def refresh(observations) when is_list(observations) do
    now = System.monotonic_time(:millisecond)

    Enum.each(observations, fn obs ->
      id = Map.get(obs, "id") || Map.get(obs, :id)

      if id != nil do
        str_id = to_string(id)
        maybe_evict_oldest()
        :ets.insert(@table, {str_id, obs, now})
      else
        Logger.warning("[ObservationCache] Skipping observation without id: #{inspect(obs)}")
      end
    end)

    broadcast_update()
    :ok
  end

  @doc "Delete all entries from the cache."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Return aggregate stats for the cache.

      %{count: non_neg_integer(), oldest: DateTime.t() | nil, newest: DateTime.t() | nil}
  """
  @spec stats() :: %{count: non_neg_integer(), oldest: DateTime.t() | nil, newest: DateTime.t() | nil}
  def stats do
    now = System.monotonic_time(:millisecond)

    live_entries =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_id, _obs, inserted_at} -> now - inserted_at <= @ttl_ms end)

    count = length(live_entries)

    {oldest, newest} =
      if count == 0 do
        {nil, nil}
      else
        timestamps = Enum.map(live_entries, fn {_id, _obs, inserted_at} -> inserted_at end)
        min_ms = Enum.min(timestamps)
        max_ms = Enum.max(timestamps)
        {monotonic_ms_to_datetime(min_ms), monotonic_ms_to_datetime(max_ms)}
      end

    %{count: count, oldest: oldest, newest: newest}
  end

  # ── GenServer Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    schedule_sweep()
    Logger.debug("[ObservationCache] ETS table #{@table} initialized")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:sweep_expired, state) do
    sweep_expired_entries()
    schedule_sweep()
    {:noreply, state}
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  @spec schedule_sweep() :: reference()
  defp schedule_sweep do
    Process.send_after(self(), :sweep_expired, @sweep_interval_ms)
  end

  @spec sweep_expired_entries() :: non_neg_integer()
  defp sweep_expired_entries do
    now = System.monotonic_time(:millisecond)

    deleted =
      :ets.tab2list(@table)
      |> Enum.reduce(0, fn {id, _obs, inserted_at}, acc ->
        if now - inserted_at > @ttl_ms do
          :ets.delete(@table, id)
          acc + 1
        else
          acc
        end
      end)

    if deleted > 0 do
      Logger.debug("[ObservationCache] Swept #{deleted} expired entries")
    end

    deleted
  end

  @spec maybe_evict_oldest() :: :ok
  defp maybe_evict_oldest do
    if :ets.info(@table, :size) >= @max_entries do
      case :ets.tab2list(@table) do
        [] ->
          :ok

        entries ->
          {oldest_id, _obs, _inserted_at} =
            Enum.min_by(entries, fn {_id, _obs, inserted_at} -> inserted_at end)

          :ets.delete(@table, oldest_id)
          Logger.debug("[ObservationCache] Evicted oldest entry #{oldest_id} (LRU)")
          :ok
      end
    else
      :ok
    end
  end

  @spec broadcast_update() :: :ok | {:error, term()}
  defp broadcast_update do
    now = System.monotonic_time(:millisecond)

    count =
      :ets.tab2list(@table)
      |> Enum.count(fn {_id, _obs, inserted_at} -> now - inserted_at <= @ttl_ms end)

    Phoenix.PubSub.broadcast(ApmV5.PubSub, @pubsub_topic, {:observations_updated, count})
  end

  @spec apply_limit([term()], non_neg_integer() | :infinity) :: [term()]
  defp apply_limit(list, :infinity), do: list
  defp apply_limit(list, limit) when is_integer(limit) and limit >= 0, do: Enum.take(list, limit)

  @spec narrative_matches?(map(), String.t()) :: boolean()
  defp narrative_matches?(%{"narrative" => narrative}, query) when is_binary(narrative) do
    String.contains?(String.downcase(narrative), query)
  end

  defp narrative_matches?(%{narrative: narrative}, query) when is_binary(narrative) do
    String.contains?(String.downcase(narrative), query)
  end

  defp narrative_matches?(_obs, _query), do: false

  @spec monotonic_ms_to_datetime(integer()) :: DateTime.t()
  defp monotonic_ms_to_datetime(monotonic_ms) do
    wall_ms =
      System.os_time(:millisecond) -
        System.monotonic_time(:millisecond) +
        monotonic_ms

    DateTime.from_unix!(wall_ms, :millisecond)
  end
end
