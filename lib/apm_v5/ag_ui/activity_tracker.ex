defmodule ApmV5.AgUi.ActivityTracker do
  @moduledoc """
  Tracks per-agent activity status for real-time 'what is happening' displays.

  ## US-016 Acceptance Criteria (DoD):
  - GenServer tracks per-agent activity (idle, thinking, executing_tool, writing_code, etc.)
  - Emits ACTIVITY_SNAPSHOT via EventBus on new SSE connection
  - Emits ACTIVITY_DELTA when agent activity changes (triggered by STEP/TOOL events)
  - Activity inferred from event types
  - get_activity/1 returns current activity; list_activities/0 returns all
  - mix compile --warnings-as-errors passes
  """

  use GenServer

  require Logger

  alias ApmV5.AgUi.EventBus

  # -- Client API -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns current activity for an agent."
  @spec get_activity(String.t()) :: map() | nil
  def get_activity(agent_id) do
    GenServer.call(__MODULE__, {:get_activity, agent_id})
  end

  @doc "Returns all agent activities."
  @spec list_activities() :: map()
  def list_activities do
    GenServer.call(__MODULE__, :list_activities)
  end

  @doc "Emits ACTIVITY_SNAPSHOT for a new SSE connection."
  @spec emit_snapshot() :: :ok
  def emit_snapshot do
    GenServer.cast(__MODULE__, :emit_snapshot)
  end

  # -- GenServer Callbacks ----------------------------------------------------

  @impl true
  def init(_opts) do
    EventBus.subscribe("lifecycle:*")
    EventBus.subscribe("tool:*")
    EventBus.subscribe("thinking:*")
    EventBus.subscribe("text:*")
    EventBus.subscribe("activity:*")

    {:ok, %{activities: %{}}}
  end

  @impl true
  def handle_call({:get_activity, agent_id}, _from, state) do
    {:reply, Map.get(state.activities, agent_id), state}
  end

  def handle_call(:list_activities, _from, state) do
    {:reply, state.activities, state}
  end

  @impl true
  def handle_cast(:emit_snapshot, state) do
    EventBus.publish("ACTIVITY_SNAPSHOT", %{
      activities: state.activities,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    {:noreply, state}
  end

  @impl true
  def handle_info({:event_bus, _topic, event}, state) do
    new_state = infer_activity(event, state)

    if new_state != state do
      # Find the changed agent and emit ACTIVITY_DELTA
      changed =
        Enum.find(Map.keys(new_state.activities), fn id ->
          Map.get(new_state.activities, id) != Map.get(state.activities, id)
        end)

      if changed do
        EventBus.publish("ACTIVITY_DELTA", %{
          agent_id: changed,
          activity: Map.get(new_state.activities, changed),
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        })
      end
    end

    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private ----------------------------------------------------------------

  defp infer_activity(%{type: type, data: data}, state) when is_map(data) do
    agent_id = data[:agent_id]
    if is_nil(agent_id), do: throw(:skip)

    activity =
      case type do
        "TOOL_CALL_START" ->
          %{
            status: "executing_tool",
            tool_name: data[:tool_name],
            since: DateTime.utc_now() |> DateTime.to_iso8601()
          }

        "TOOL_CALL_END" ->
          %{
            status: "idle",
            since: DateTime.utc_now() |> DateTime.to_iso8601()
          }

        "THINKING_START" ->
          %{
            status: "thinking",
            since: DateTime.utc_now() |> DateTime.to_iso8601()
          }

        "THINKING_END" ->
          %{
            status: "idle",
            since: DateTime.utc_now() |> DateTime.to_iso8601()
          }

        "TEXT_MESSAGE_START" ->
          %{
            status: "responding",
            since: DateTime.utc_now() |> DateTime.to_iso8601()
          }

        "TEXT_MESSAGE_END" ->
          %{
            status: "idle",
            since: DateTime.utc_now() |> DateTime.to_iso8601()
          }

        "STEP_STARTED" ->
          %{
            status: "working",
            step_name: data[:step_name],
            since: DateTime.utc_now() |> DateTime.to_iso8601()
          }

        "STEP_FINISHED" ->
          %{
            status: "idle",
            since: DateTime.utc_now() |> DateTime.to_iso8601()
          }

        "RUN_STARTED" ->
          %{
            status: "starting",
            since: DateTime.utc_now() |> DateTime.to_iso8601()
          }

        "RUN_FINISHED" ->
          %{
            status: "completed",
            since: DateTime.utc_now() |> DateTime.to_iso8601()
          }

        "RUN_ERROR" ->
          %{
            status: "error",
            since: DateTime.utc_now() |> DateTime.to_iso8601()
          }

        _ ->
          nil
      end

    if activity do
      %{state | activities: Map.put(state.activities, agent_id, activity)}
    else
      state
    end
  catch
    :skip -> state
  end

  defp infer_activity(_event, state), do: state
end
