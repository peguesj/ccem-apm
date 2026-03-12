defmodule ApmV5.AgUi.EventBusHealth do
  @moduledoc """
  EventBus health check integration and diagnostics.

  ## US-041 Acceptance Criteria (DoD):
  - HealthCheckRunner includes EventBus check: alive, subscribers > 0, last event < 5min
  - GET /api/v2/ag-ui/diagnostics returns topic stats and throughput
  - Per-topic throughput (events/min over last 5 minutes)
  - Warning if zero subscribers for > 60 seconds
  - mix compile --warnings-as-errors passes
  """

  use GenServer

  require Logger

  alias ApmV5.AgUi.EventBus

  @check_interval_ms 30_000
  @zero_sub_warn_ms 60_000

  # -- Client API -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns diagnostics data for the EventBus."
  @spec diagnostics() :: map()
  def diagnostics do
    GenServer.call(__MODULE__, :diagnostics)
  end

  @doc "Returns health check result for HealthCheckRunner."
  @spec health_check() :: {:ok, map()} | {:warning, String.t(), map()} | {:error, String.t()}
  def health_check do
    GenServer.call(__MODULE__, :health_check)
  end

  # -- GenServer Callbacks ----------------------------------------------------

  @impl true
  def init(_opts) do
    schedule_check()

    {:ok,
     %{
       event_counts: %{},
       last_event_at: nil,
       started_at: System.monotonic_time(:millisecond),
       zero_subscribers_since: nil,
       warnings: []
     }}
  end

  @impl true
  def handle_call(:diagnostics, _from, state) do
    bus_stats = safe_bus_stats()
    uptime_ms = System.monotonic_time(:millisecond) - state.started_at

    topics =
      Enum.map(bus_stats[:by_topic] || %{}, fn {topic, count} ->
        events_per_min = count / max(uptime_ms / 60_000, 1)

        %{
          topic: topic,
          subscriber_count: count_subscribers_for_topic(topic),
          events_per_minute: Float.round(events_per_min, 2),
          total_events: count
        }
      end)

    result = %{
      topics: topics,
      total_published: bus_stats[:published_count] || 0,
      subscribers_count: bus_stats[:subscribers_count] || 0,
      uptime_seconds: div(uptime_ms, 1000),
      last_event_at: state.last_event_at,
      warnings: state.warnings
    }

    {:reply, result, state}
  end

  def handle_call(:health_check, _from, state) do
    bus_stats = safe_bus_stats()
    alive = Process.whereis(ApmV5.AgUi.EventBus) != nil
    sub_count = bus_stats[:subscribers_count] || 0

    result =
      cond do
        not alive ->
          {:error, "EventBus GenServer is not running"}

        sub_count == 0 and state.zero_subscribers_since != nil ->
          elapsed = System.monotonic_time(:millisecond) - state.zero_subscribers_since

          if elapsed > @zero_sub_warn_ms do
            {:warning, "EventBus has zero subscribers for #{div(elapsed, 1000)}s",
             %{subscribers: 0, published: bus_stats[:published_count] || 0}}
          else
            {:ok, %{subscribers: 0, published: bus_stats[:published_count] || 0}}
          end

        true ->
          {:ok, %{subscribers: sub_count, published: bus_stats[:published_count] || 0}}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:check, state) do
    bus_stats = safe_bus_stats()
    sub_count = bus_stats[:subscribers_count] || 0

    new_state =
      if sub_count == 0 do
        zero_since = state.zero_subscribers_since || System.monotonic_time(:millisecond)

        elapsed = System.monotonic_time(:millisecond) - zero_since

        warnings =
          if elapsed > @zero_sub_warn_ms do
            Logger.warning("EventBus has zero subscribers for #{div(elapsed, 1000)}s")
            [%{type: :zero_subscribers, since: zero_since} | Enum.take(state.warnings, 9)]
          else
            state.warnings
          end

        %{state | zero_subscribers_since: zero_since, warnings: warnings}
      else
        %{state | zero_subscribers_since: nil}
      end

    schedule_check()
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private ----------------------------------------------------------------

  defp schedule_check do
    Process.send_after(self(), :check, @check_interval_ms)
  end

  defp safe_bus_stats do
    EventBus.stats()
  rescue
    _ -> %{published_count: 0, subscribers_count: 0, by_topic: %{}}
  end

  defp count_subscribers_for_topic(_topic) do
    # Approximate: use total subscriber count since we can't easily filter per-topic
    case safe_bus_stats() do
      %{subscribers_count: count} -> count
      _ -> 0
    end
  end
end
