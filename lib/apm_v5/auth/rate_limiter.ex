defmodule ApmV5.Auth.RateLimiter do
  @moduledoc """
  GenServer implementing sliding window rate limiting for AgentLock.

  Tracks tool call frequency per `{user_id, tool_name}` tuple with
  configurable limits per tool. Uses ETS for O(1) lookups.

  ## Algorithm
  Sliding window: maintains list of timestamps, prunes older than
  window_seconds on each check. If remaining count >= max_calls,
  returns rate limit error with retry_after_ms.

  ## ETS Table
  `:agentlock_rate_limits` — keyed by `{user_id, tool_name}` tuple
  """

  use GenServer

  require Logger

  @table :agentlock_rate_limits
  @config_table :agentlock_rate_configs
  @prune_interval_ms 30_000

  # Default rate limits per risk level
  @default_limits %{
    none: %{max_calls: 1000, window_seconds: 60},
    low: %{max_calls: 200, window_seconds: 60},
    medium: %{max_calls: 50, window_seconds: 60},
    high: %{max_calls: 20, window_seconds: 60},
    critical: %{max_calls: 5, window_seconds: 60}
  }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if a tool call is within rate limits.

  Returns `:ok` if allowed, `{:error, :rate_limited, retry_after_ms}` if exceeded.
  """
  @spec check(String.t(), String.t()) :: :ok | {:error, :rate_limited, non_neg_integer()}
  def check(user_id, tool_name) do
    key = {user_id, tool_name}
    config = get_tool_config(tool_name)
    now_ms = System.system_time(:millisecond)
    window_ms = config.window_seconds * 1000
    cutoff = now_ms - window_ms

    timestamps =
      case :ets.lookup(@table, key) do
        [{^key, ts_list}] -> Enum.filter(ts_list, &(&1 > cutoff))
        [] -> []
      end

    if length(timestamps) >= config.max_calls do
      # Calculate retry_after from oldest timestamp in window
      oldest = Enum.min(timestamps)
      retry_after = oldest + window_ms - now_ms
      {:error, :rate_limited, max(retry_after, 1000)}
    else
      :ok
    end
  end

  @doc """
  Record a tool call event (advances the sliding window).
  """
  @spec record(String.t(), String.t()) :: :ok
  def record(user_id, tool_name) do
    GenServer.cast(__MODULE__, {:record, user_id, tool_name})
  end

  @doc """
  Configure rate limits for a specific tool.
  """
  @spec configure(String.t(), non_neg_integer(), non_neg_integer()) :: :ok
  def configure(tool_name, max_calls, window_seconds) do
    GenServer.call(__MODULE__, {:configure, tool_name, max_calls, window_seconds})
  end

  @doc "Get current rate limit config for a tool."
  @spec get_tool_config(String.t()) :: map()
  def get_tool_config(tool_name) do
    case :ets.lookup(@config_table, tool_name) do
      [{^tool_name, config}] -> config
      [] -> @default_limits[:low]
    end
  end

  @doc "Get rate limit utilization stats for all active keys."
  @spec stats() :: [map()]
  def stats do
    now_ms = System.system_time(:millisecond)

    :ets.tab2list(@table)
    |> Enum.map(fn {{user_id, tool_name}, timestamps} ->
      config = get_tool_config(tool_name)
      cutoff = now_ms - config.window_seconds * 1000
      active = Enum.count(timestamps, &(&1 > cutoff))

      %{
        user_id: user_id,
        tool_name: tool_name,
        current_calls: active,
        max_calls: config.max_calls,
        window_seconds: config.window_seconds,
        utilization: if(config.max_calls > 0, do: active / config.max_calls, else: 0.0)
      }
    end)
    |> Enum.filter(&(&1.current_calls > 0))
    |> Enum.sort_by(& &1.utilization, :desc)
  end

  @doc "Returns the default rate limits map."
  @spec default_limits() :: map()
  def default_limits, do: @default_limits

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@config_table, [:named_table, :set, :public, read_concurrency: true])
    schedule_prune()
    Logger.info("[RateLimiter] Started — tables #{@table}, #{@config_table}")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:configure, tool_name, max_calls, window_seconds}, _from, state) do
    config = %{max_calls: max_calls, window_seconds: window_seconds}
    :ets.insert(@config_table, {tool_name, config})
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:record, user_id, tool_name}, state) do
    key = {user_id, tool_name}
    now_ms = System.system_time(:millisecond)

    existing =
      case :ets.lookup(@table, key) do
        [{^key, ts_list}] -> ts_list
        [] -> []
      end

    :ets.insert(@table, {key, [now_ms | existing]})
    {:noreply, state}
  end

  @impl true
  def handle_info(:prune_stale, state) do
    prune_stale_entries()
    schedule_prune()
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp prune_stale_entries do
    now_ms = System.system_time(:millisecond)
    # Remove timestamps older than the maximum window (60s default)
    max_window_ms = 120_000

    :ets.tab2list(@table)
    |> Enum.each(fn {key, timestamps} ->
      pruned = Enum.filter(timestamps, &(&1 > now_ms - max_window_ms))

      if pruned == [] do
        :ets.delete(@table, key)
      else
        :ets.insert(@table, {key, pruned})
      end
    end)
  end

  defp schedule_prune do
    Process.send_after(self(), :prune_stale, @prune_interval_ms)
  end
end
