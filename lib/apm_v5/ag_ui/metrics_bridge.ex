defmodule ApmV5.AgUi.MetricsBridge do
  @moduledoc """
  Bridges EventBus events to MetricsCollector counters.

  ## US-039 Acceptance Criteria (DoD):
  - GenServer subscribes to EventBus 'lifecycle:*', 'tool:*', 'state:*' topics
  - Lifecycle events increment agent_runs_total, agent_steps_total
  - Tool events increment tool_calls_total, update tool_call_duration_ms
  - State events increment state_snapshots_total, state_deltas_total
  - Metrics available via existing GET /api/v2/metrics endpoint
  - mix compile --warnings-as-errors passes
  """

  use GenServer

  require Logger

  alias ApmV5.AgUi.EventBus

  # -- Client API -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # -- GenServer Callbacks ----------------------------------------------------

  @impl true
  def init(_opts) do
    EventBus.subscribe("lifecycle:*")
    EventBus.subscribe("tool:*")
    EventBus.subscribe("state:*")

    {:ok, %{}}
  end

  @impl true
  def handle_info({:event_bus, _topic, event}, state) do
    record_metric(event)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private ----------------------------------------------------------------

  defp record_metric(%{type: type, data: data}) when is_map(data) do
    agent_id = data[:agent_id] || "system"

    case type do
      "RUN_STARTED" ->
        safe_record(agent_id, "agent_runs_total", 1)

      "RUN_FINISHED" ->
        safe_record(agent_id, "agent_runs_completed", 1)

      "RUN_ERROR" ->
        safe_record(agent_id, "agent_runs_errors", 1)

      "STEP_STARTED" ->
        safe_record(agent_id, "agent_steps_total", 1)

      "STEP_FINISHED" ->
        safe_record(agent_id, "agent_steps_completed", 1)

      "TOOL_CALL_START" ->
        safe_record(agent_id, "tool_calls_total", 1)

      "TOOL_CALL_END" ->
        safe_record(agent_id, "tool_calls_completed", 1)
        if data[:duration_ms] do
          safe_record(agent_id, "tool_call_duration_ms", data[:duration_ms])
        end

      "STATE_SNAPSHOT" ->
        safe_record(agent_id, "state_snapshots_total", 1)

      "STATE_DELTA" ->
        safe_record(agent_id, "state_deltas_total", 1)

      _ ->
        :ok
    end
  end

  defp record_metric(_event), do: :ok

  defp safe_record(agent_id, metric, value) do
    ApmV5.MetricsCollector.record(agent_id, metric, value)
  rescue
    _ -> :ok
  end
end
