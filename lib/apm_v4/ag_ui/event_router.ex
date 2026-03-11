defmodule ApmV4.AgUi.EventRouter do
  @moduledoc """
  Routes incoming AG-UI events to appropriate APM handlers.

  Acts as the central event dispatcher, receiving events from:
  - Direct AG-UI emit API calls
  - HookBridge translations from legacy endpoints
  - Internal GenServer state changes

  Routes events to:
  - AgentRegistry (lifecycle events: RUN_STARTED, RUN_FINISHED, RUN_ERROR)
  - FormationStore (formation-tagged events)
  - DashboardStore (all events for recent activity)
  - MetricsCollector (telemetry tracking)
  """

  use GenServer

  alias ApmV4.EventStream

  @pubsub ApmV4.PubSub

  # -- Client API -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Routes an AG-UI event to appropriate handlers based on event type.

  Returns :ok after routing completes.
  """
  @spec route(map()) :: :ok
  def route(event) do
    GenServer.cast(__MODULE__, {:route, event})
  end

  @doc """
  Emits an AG-UI event through EventStream and routes it.

  Convenience function that combines emit + route in a single call.
  """
  @spec emit_and_route(String.t(), map()) :: map()
  def emit_and_route(type, data) do
    event = EventStream.emit(type, data)
    route(event)
    event
  end

  @doc "Returns routing stats."
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # -- GenServer Callbacks ----------------------------------------------------

  @impl true
  def init(_opts) do
    # NOTE: We do NOT subscribe to ag_ui:events PubSub here.
    # EventStream.emit broadcasts to that topic, and if we subscribed
    # we'd create a feedback loop (every emitted event gets re-routed).
    # Instead, routing happens explicitly via route/1 or emit_and_route/2,
    # and the HookBridge calls in ApiController trigger emit which handles broadcast.

    {:ok,
     %{
       routed_count: 0,
       by_type: %{},
       last_routed_at: nil
     }}
  end

  @impl true
  def handle_cast({:route, event}, state) do
    do_route(event)
    {:noreply, update_stats(state, event)}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # -- Routing Logic ----------------------------------------------------------

  defp do_route(%{type: type, data: data} = _event) do
    case type do
      "RUN_STARTED" ->
        route_to_agent_registry(:run_started, data)
        route_to_formation(data)

      "RUN_FINISHED" ->
        route_to_agent_registry(:run_finished, data)
        route_to_formation(data)

      "RUN_ERROR" ->
        route_to_agent_registry(:run_error, data)
        route_to_formation(data)

      "STEP_STARTED" ->
        route_to_agent_registry(:step_started, data)

      "STEP_FINISHED" ->
        route_to_agent_registry(:step_finished, data)

      "TOOL_CALL_START" ->
        route_to_metrics(:tool_call, data)

      "TOOL_CALL_END" ->
        route_to_metrics(:tool_call_end, data)

      "STATE_SNAPSHOT" ->
        route_to_dashboard(:state_snapshot, data)

      "STATE_DELTA" ->
        route_to_dashboard(:state_delta, data)

      "CUSTOM" ->
        route_custom(data)

      _ ->
        :ok
    end
  end

  defp do_route(_event), do: :ok

  defp route_to_agent_registry(event_type, data) do
    agent_id = data[:agent_id]

    if agent_id do
      case event_type do
        :run_started ->
          ApmV4.AgentRegistry.register_agent(agent_id, %{
            status: "active",
            last_seen: DateTime.utc_now() |> DateTime.to_iso8601(),
            metadata: data[:metadata]
          })

        :run_finished ->
          ApmV4.AgentRegistry.register_agent(agent_id, %{
            status: "completed",
            last_seen: DateTime.utc_now() |> DateTime.to_iso8601()
          })

        :run_error ->
          ApmV4.AgentRegistry.register_agent(agent_id, %{
            status: "error",
            last_seen: DateTime.utc_now() |> DateTime.to_iso8601(),
            error: data[:message]
          })

        :step_started ->
          ApmV4.AgentRegistry.register_agent(agent_id, %{
            status: "active",
            last_seen: DateTime.utc_now() |> DateTime.to_iso8601(),
            current_step: data[:step_name]
          })

        :step_finished ->
          ApmV4.AgentRegistry.register_agent(agent_id, %{
            last_seen: DateTime.utc_now() |> DateTime.to_iso8601()
          })
      end
    end
  rescue
    _ -> :ok
  end

  defp route_to_formation(data) do
    formation_id = get_in(data, [:metadata, :formation_id])

    if formation_id do
      # Notify FormationStore if it exists
      try do
        ApmV4.UpmStore.record_event(%{"formation_id" => formation_id, "data" => data})
      rescue
        _ -> :ok
      end
    end
  end

  defp route_to_dashboard(event_type, data) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "dashboard:updates",
      {:ag_ui_dashboard, event_type, data}
    )
  rescue
    _ -> :ok
  end

  defp route_to_metrics(event_type, data) do
    try do
      ApmV4.MetricsCollector.record(data[:agent_id] || "system", to_string(event_type), 1)
    rescue
      _ -> :ok
    end
  end

  defp route_custom(data) do
    case data[:name] do
      "notification" ->
        try do
          ApmV4.AgentRegistry.add_notification(%{
            title: get_in(data, [:value, :title]) || "AG-UI Event",
            message: get_in(data, [:value, :message]) || "",
            level: get_in(data, [:value, :level]) || "info",
            category: get_in(data, [:value, :category]) || "ag-ui",
            timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
          })
        rescue
          _ -> :ok
        end

      "heartbeat" ->
        route_to_agent_registry(:step_started, data)

      _ ->
        :ok
    end
  end

  defp update_stats(state, %{type: type}) do
    %{
      state
      | routed_count: state.routed_count + 1,
        by_type: Map.update(state.by_type, type, 1, &(&1 + 1)),
        last_routed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp update_stats(state, _), do: state
end
