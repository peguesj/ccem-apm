defmodule ApmV5.StatusCache do
  @moduledoc """
  ETS-backed cache for expensive aggregate status responses.

  Primary consumer: CCEMHelper polls `/api/status` every 3s and the payload
  requires aggregating over all projects × agents (O(projects × agents)).

  Cache is public ETS, 1 second TTL, `{:read_concurrency, true}` so all
  Phoenix request workers read in parallel without any GenServer serialization.

  Writes go through GenServer to guarantee single-rebuild on miss.

  ## Eager warmup (v8.11.1 / US-601)

  On start, this GenServer uses `handle_continue(:warmup, _)` to populate both
  `:status_payload` and `:health_payload` asynchronously via `Task.start/1`.
  This ensures the first `/api/status` and `/health` requests after boot hit a
  warm cache (<50ms) instead of performing a full aggregation on-demand.

  It also schedules periodic proactive refresh every `@refresh_ms` (500ms, half
  the TTL) so the cache is continuously kept warm even without request traffic.
  """

  use GenServer
  require Logger

  @table :apm_status_cache
  # 1 second cache TTL — CCEMHelper polls /api/status every 3s
  @ttl_ms 1_000
  # Proactive refresh interval — half the TTL to guarantee cache is always warm
  @refresh_ms 500

  # --- Client API ---

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns cached value for `key` or computes it via `compute_fn` on miss/expiry.

  Cache hit path: one :ets.lookup/2 + monotonic time comparison. No GenServer.call.
  Cache miss path: forwards to GenServer to guarantee single-build-per-key.
  """
  @spec fetch(atom(), (-> term())) :: term()
  def fetch(key, compute_fn) when is_atom(key) and is_function(compute_fn, 0) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        value

      _ ->
        GenServer.call(__MODULE__, {:compute, key, compute_fn}, 15_000)
    end
  end

  @doc "Invalidate a cached key (forces next fetch to rebuild)."
  @spec invalidate(atom()) :: :ok
  def invalidate(key) when is_atom(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc "Check whether a key is currently warm (present and not expired)."
  @spec warm?(atom()) :: boolean()
  def warm?(key) when is_atom(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, _value, expires_at}] when expires_at > now -> true
      _ -> false
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}, {:continue, :warmup}}
  end

  @impl true
  def handle_continue(:warmup, state) do
    # Spawn async warmup tasks so init() returns fast and does not block
    # the supervision tree. Tasks post results via GenServer.cast.
    warmup_async(:status_payload, &ApmV5.StatusPayloadBuilder.build_status_payload/0)
    warmup_async(:health_payload, &ApmV5.StatusPayloadBuilder.build_health_payload/0)

    # Notify via PubSub that warmup started (used by BootReporter)
    safe_broadcast("apm:boot", {:status_cache_warmup_started, System.monotonic_time(:millisecond)})

    # Schedule periodic refresh
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    # Proactive refresh: rebuild both hot payloads in background
    warmup_async(:status_payload, &ApmV5.StatusPayloadBuilder.build_status_payload/0)
    warmup_async(:health_payload, &ApmV5.StatusPayloadBuilder.build_health_payload/0)
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call({:compute, key, compute_fn}, _from, state) do
    now = System.monotonic_time(:millisecond)

    # Double-check after acquiring serialization: another caller may have
    # already populated the cache while we were queued.
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        {:reply, value, state}

      _ ->
        value = compute_fn.()
        expires_at = now + @ttl_ms
        :ets.insert(@table, {key, value, expires_at})
        {:reply, value, state}
    end
  end

  @impl true
  def handle_cast({:warmup_done, key, value}, state) do
    now = System.monotonic_time(:millisecond)
    expires_at = now + @ttl_ms
    :ets.insert(@table, {key, value, expires_at})

    # Broadcast warmup completion for the first warmup pass only
    safe_broadcast("apm:boot", {:status_cache_warmup_complete, key, now})
    {:noreply, state}
  end

  # --- Private ---

  defp warmup_async(key, compute_fn) do
    server = self()

    Task.start(fn ->
      try do
        value = compute_fn.()
        GenServer.cast(server, {:warmup_done, key, value})
      rescue
        error ->
          Logger.warning("StatusCache warmup failed for #{inspect(key)}: #{inspect(error)}")
      catch
        :exit, reason ->
          Logger.warning("StatusCache warmup exited for #{inspect(key)}: #{inspect(reason)}")
      end
    end)
  end

  defp safe_broadcast(topic, msg) do
    try do
      Phoenix.PubSub.broadcast(ApmV5.PubSub, topic, msg)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end
