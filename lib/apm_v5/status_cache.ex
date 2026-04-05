defmodule ApmV5.StatusCache do
  @moduledoc """
  ETS-backed cache for expensive aggregate status responses.

  Primary consumer: CCEMHelper polls `/api/status` every 3s and the payload
  requires aggregating over all projects × agents (O(projects × agents)).

  Cache is public ETS, 1 second TTL, `{:read_concurrency, true}` so all
  Phoenix request workers read in parallel without any GenServer serialization.

  Writes go through GenServer to guarantee single-rebuild on miss.
  """

  use GenServer

  @table :apm_status_cache
  # 1 second cache TTL — CCEMHelper polls /api/status every 3s
  @ttl_ms 1_000

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

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
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
end
