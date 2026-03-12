defmodule ApmV5.AgUi.DashboardStateSync do
  @moduledoc """
  Aggregates all agent states into a single dashboard state object and
  emits STATE_DELTA events when any agent's state changes.

  ## US-015 Acceptance Criteria (DoD):
  - GenServer maintains aggregated dashboard state (agents, formations, metrics)
  - Subscribes to EventBus 'lifecycle:*' and 'state:*' topics
  - On agent registration/update: computes STATE_DELTA for dashboard aggregate
  - get_dashboard_snapshot/0 returns full dashboard state
  - STATE_DELTA events include path prefixes like /agents/<id>/status
  - mix compile --warnings-as-errors passes
  """

  use GenServer

  require Logger

  alias ApmV5.AgUi.EventBus

  @pubsub ApmV5.PubSub

  # -- Client API -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the full aggregated dashboard state."
  @spec get_dashboard_snapshot() :: map()
  def get_dashboard_snapshot do
    GenServer.call(__MODULE__, :get_snapshot)
  end

  # -- GenServer Callbacks ----------------------------------------------------

  @impl true
  def init(_opts) do
    EventBus.subscribe("lifecycle:*")
    EventBus.subscribe("state:*")

    {:ok,
     %{
       agents: %{},
       formations: %{},
       metrics: %{
         total_events: 0,
         active_agents: 0,
         total_tool_calls: 0
       },
       version: 0
     }}
  end

  @impl true
  def handle_call(:get_snapshot, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info({:event_bus, _topic, event}, state) do
    new_state = process_event(event, state)

    if new_state != state do
      delta = compute_state_delta(state, new_state)
      broadcast_delta(delta, new_state.version)
    end

    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private ----------------------------------------------------------------

  defp process_event(%{type: type, data: data}, state) when is_map(data) do
    agent_id = data[:agent_id]

    case type do
      "RUN_STARTED" ->
        update_agent(state, agent_id, %{
          status: "active",
          run_id: data[:run_id],
          started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          metadata: data[:metadata]
        })

      "RUN_FINISHED" ->
        update_agent(state, agent_id, %{
          status: "completed",
          finished_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })

      "RUN_ERROR" ->
        update_agent(state, agent_id, %{
          status: "error",
          error: data[:message]
        })

      "STEP_STARTED" ->
        update_agent(state, agent_id, %{
          current_step: data[:step_name],
          status: "active"
        })

      "STEP_FINISHED" ->
        update_agent(state, agent_id, %{
          current_step: nil
        })

      "STATE_SNAPSHOT" ->
        if agent_id do
          update_agent(state, agent_id, %{state_version: data[:version]})
        else
          state
        end

      _ ->
        state
    end
    |> bump_metrics(type)
  end

  defp process_event(_event, state), do: state

  defp update_agent(state, nil, _updates), do: state

  defp update_agent(state, agent_id, updates) do
    current = Map.get(state.agents, agent_id, %{})
    updated = Map.merge(current, updates)
    agents = Map.put(state.agents, agent_id, updated)

    active_count =
      agents
      |> Enum.count(fn {_id, a} -> a[:status] == "active" end)

    %{
      state
      | agents: agents,
        version: state.version + 1,
        metrics: %{state.metrics | active_agents: active_count}
    }
  end

  defp bump_metrics(state, type) do
    metrics = state.metrics

    metrics =
      case type do
        "TOOL_CALL_START" ->
          %{metrics | total_tool_calls: metrics.total_tool_calls + 1}

        _ ->
          metrics
      end

    %{state | metrics: %{metrics | total_events: metrics.total_events + 1}}
  end

  defp compute_state_delta(old_state, new_state) do
    ops = []

    # Compare agents
    all_agent_ids =
      MapSet.union(
        MapSet.new(Map.keys(old_state.agents)),
        MapSet.new(Map.keys(new_state.agents))
      )

    agent_ops =
      Enum.flat_map(all_agent_ids, fn id ->
        old_agent = Map.get(old_state.agents, id)
        new_agent = Map.get(new_state.agents, id)

        cond do
          is_nil(old_agent) and not is_nil(new_agent) ->
            [%{"op" => "add", "path" => "/agents/#{id}", "value" => new_agent}]

          not is_nil(old_agent) and is_nil(new_agent) ->
            [%{"op" => "remove", "path" => "/agents/#{id}"}]

          old_agent != new_agent ->
            Enum.flat_map(Map.keys(new_agent), fn key ->
              if Map.get(old_agent, key) != Map.get(new_agent, key) do
                [%{
                  "op" => "replace",
                  "path" => "/agents/#{id}/#{key}",
                  "value" => Map.get(new_agent, key)
                }]
              else
                []
              end
            end)

          true ->
            []
        end
      end)

    ops ++ agent_ops
  end

  defp broadcast_delta(delta, version) when delta != [] do
    EventBus.publish("STATE_DELTA", %{
      delta: delta,
      version: version,
      source: "dashboard_sync"
    })

    Phoenix.PubSub.broadcast(
      @pubsub,
      "dashboard:updates",
      {:ag_ui_dashboard, :state_delta, %{delta: delta, version: version}}
    )
  rescue
    _ -> :ok
  end

  defp broadcast_delta(_delta, _version), do: :ok
end
