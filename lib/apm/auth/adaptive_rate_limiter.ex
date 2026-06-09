defmodule Apm.Auth.AdaptiveRateLimiter do
  @moduledoc """
  Load-aware adaptive rate limiter that adjusts formation bucket sizes based on
  observed BEAM VM backpressure.

  ## Design

  Every `@sample_interval_ms` (5 000 ms) this GenServer samples the message
  queue length of `Apm.AgentRegistry` as a representative load signal for the
  entire APM process group.  A *load factor* in `[0.1, 1.0]` is derived from
  the queue depth:

      load_factor = clamp(1.0 - queue_len / 50, 0.1, 1.0)

  When `queue_len > 50` (overloaded), `load_factor < 1.0` and
  `FormationRateLimiter` buckets are scaled **down** proportionally.
  When the queue stays below 10 for 30 consecutive seconds (≥ 6 samples) the
  load factor is reset to `1.0` and buckets are restored.

  ## Integration with FormationRateLimiter

  `FormationRateLimiter` delegates its per-agent limit calculation through the
  optional `adaptive_factor/0` callback exported here.  When the factor is
  `1.0` there is no effective change to existing budgets.  When it drops
  below `1.0`, `FormationRateLimiter.formation_budget/2` is multiplied by the
  factor before the Hammer window is checked.

  Callers import just `Apm.Auth.AdaptiveRateLimiter.adaptive_factor/0`; this
  GenServer manages state internally.

  ## Telemetry

  Emits `[:apm, :rate_limiter, :adaptive, :scaled]` with
  `%{factor: float, queue_len: integer}` on every scaling decision that changes
  the current factor.

  ## PubSub

  Broadcasts `{:adaptive_scaled, factor}` on topic `"apm:rate_limits"` so the
  dashboard widget can update its sparkline in real time.
  """

  use GenServer

  require Logger

  @sample_interval_ms 5_000
  @overload_threshold 50
  @recovery_threshold 10
  @recovery_samples_needed 6

  @factor_key {__MODULE__, :factor}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start the AdaptiveRateLimiter supervisor child."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current adaptive load factor in `[0.1, 1.0]`.

  Reads directly from `:persistent_term` — zero-copy, process-free.
  Returns `1.0` before the first sample or if the GenServer is not running.
  """
  @spec adaptive_factor() :: float()
  def adaptive_factor do
    :persistent_term.get(@factor_key, 1.0)
  rescue
    ArgumentError -> 1.0
  end

  @doc """
  Force a manual factor update (test / operator use).  Clamps to `[0.1, 1.0]`.
  """
  @spec set_factor(float()) :: :ok
  def set_factor(factor) when is_float(factor) do
    GenServer.cast(__MODULE__, {:set_factor, factor})
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :persistent_term.put(@factor_key, 1.0)
    schedule_sample()

    {:ok,
     %{
       factor: 1.0,
       recovery_count: 0,
       sample_count: 0
     }}
  end

  @impl true
  def handle_info(:sample, state) do
    queue_len = sample_queue_len()
    new_state = evaluate(queue_len, state)
    schedule_sample()
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:set_factor, raw_factor}, state) do
    factor = clamp(raw_factor)
    apply_factor(factor, state.factor, -1)
    {:noreply, %{state | factor: factor, recovery_count: 0}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp evaluate(queue_len, state) do
    cond do
      queue_len > @overload_threshold ->
        new_factor = clamp(1.0 - queue_len / 50)
        maybe_scale(new_factor, queue_len, %{state | recovery_count: 0})

      queue_len < @recovery_threshold ->
        new_recovery = state.recovery_count + 1

        if new_recovery >= @recovery_samples_needed and state.factor < 1.0 do
          maybe_scale(1.0, queue_len, %{state | recovery_count: new_recovery})
        else
          %{state | recovery_count: new_recovery}
        end

      true ->
        # Between thresholds — neither overloaded nor recovered
        %{state | recovery_count: 0}
    end
  end

  defp maybe_scale(new_factor, queue_len, state) do
    if abs(new_factor - state.factor) >= 0.01 do
      apply_factor(new_factor, state.factor, queue_len)
      %{state | factor: new_factor}
    else
      state
    end
  end

  defp apply_factor(factor, _old_factor, queue_len) do
    :persistent_term.put(@factor_key, factor)

    :telemetry.execute(
      [:apm, :rate_limiter, :adaptive, :scaled],
      %{factor: factor, queue_len: queue_len},
      %{}
    )

    Phoenix.PubSub.broadcast(
      Apm.PubSub,
      "apm:rate_limits",
      {:adaptive_scaled, factor}
    )

    Logger.info("[AdaptiveRateLimiter] factor=#{Float.round(factor, 3)} queue_len=#{queue_len}")

    # FormationRateLimiter is a pure module (no process); the updated factor
    # is read via adaptive_factor/0 on the next budget calculation automatically.
  end

  defp sample_queue_len do
    case Process.whereis(Apm.AgentRegistry) do
      nil ->
        0

      pid ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, len} -> len
          nil -> 0
        end
    end
  end

  defp clamp(value) do
    value |> max(0.1) |> min(1.0)
  end

  defp schedule_sample do
    Process.send_after(self(), :sample, @sample_interval_ms)
  end
end
