defmodule ApmV5.Proxy.RateLimiter do
  @moduledoc "Sliding window rate limiter per {scope, key}."
  use GenServer

  @table :proxy_rate_limiter
  @default_limit 100
  @default_window_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec allow?(term(), term()) :: boolean()
  def allow?(scope, key) do
    now = System.monotonic_time(:millisecond)
    bucket = {scope, key}
    window_start = now - @default_window_ms

    case :ets.lookup(@table, bucket) do
      [{^bucket, timestamps}] ->
        recent = Enum.filter(timestamps, &(&1 > window_start))
        if length(recent) < @default_limit do
          :ets.insert(@table, {bucket, [now | recent]})
          true
        else
          :ets.insert(@table, {bucket, recent})
          false
        end
      _ ->
        :ets.insert(@table, {bucket, [now]})
        true
    end
  rescue
    ArgumentError -> true
  end

  @spec check(term(), term()) :: %{allowed: boolean(), remaining: integer(), window_ms: integer()}
  def check(scope, key) do
    now = System.monotonic_time(:millisecond)
    bucket = {scope, key}
    window_start = now - @default_window_ms

    count = case :ets.lookup(@table, bucket) do
      [{^bucket, timestamps}] -> Enum.count(timestamps, &(&1 > window_start))
      _ -> 0
    end

    %{allowed: count < @default_limit, remaining: max(@default_limit - count, 0), window_ms: @default_window_ms}
  rescue
    ArgumentError -> %{allowed: true, remaining: @default_limit, window_ms: @default_window_ms}
  end

  @spec reset(term()) :: :ok
  def reset(scope) do
    :ets.tab2list(@table)
    |> Enum.each(fn {{s, k}, _ts} -> if s == scope, do: :ets.delete(@table, {s, k}) end)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true, write_concurrency: true])
    {:ok, %{}}
  end
end
