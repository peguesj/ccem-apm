defmodule ApmV5.Proxy.Cache do
  @moduledoc "ETS-backed cache with per-entry TTL and periodic sweep."
  use GenServer

  @table :proxy_cache
  @default_ttl 60
  @sweep_interval 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec get(term()) :: term() | nil
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:second) < expires_at, do: value, else: nil
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec put(term(), term(), pos_integer()) :: :ok
  def put(key, value, ttl \\ @default_ttl) do
    expires_at = System.monotonic_time(:second) + ttl
    :ets.insert(@table, {key, value, expires_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec stats() :: map()
  def stats do
    %{size: :ets.info(@table, :size), table: @table}
  rescue
    ArgumentError -> %{size: 0, table: @table}
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true, write_concurrency: true])
    :timer.send_interval(@sweep_interval, :sweep)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:second)
    :ets.tab2list(@table)
    |> Enum.each(fn {key, _val, expires_at} ->
      if now >= expires_at, do: :ets.delete(@table, key)
    end)
    {:noreply, state}
  end
end
