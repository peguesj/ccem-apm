defmodule ApmV5.AgUi.HookBridge do
  @moduledoc """
  Translates legacy CCEM APM hook payloads into AG-UI protocol events.

  Legacy hooks emit JSON payloads to endpoints like /api/register, /api/heartbeat,
  /api/notify, /api/tool-use. This bridge converts those payloads into proper
  AG-UI event types and emits them through the EventStream.

  ## Mapping

  | Legacy Endpoint      | AG-UI Event Type         |
  |---------------------|--------------------------|
  | POST /api/register  | RUN_STARTED              |
  | POST /api/heartbeat | STEP_STARTED/FINISHED    |
  | POST /api/notify    | CUSTOM                   |
  | POST /api/tool-use  | TOOL_CALL_START/ARGS/END |
  | Config reload       | STATE_DELTA              |
  """

  alias ApmV5.EventStream
  alias ApmV5.AgUi.LifecycleMapper
  alias AgUi.Core.Events.EventType

  @doc """
  Translates a legacy registration payload to a RUN_STARTED event.

  Called when POST /api/register receives a new agent/session registration.
  """
  @spec translate_register(map()) :: map()
  def translate_register(payload) do
    # US-004/US-008 DoD: Delegates to LifecycleMapper.map_registration/1 for
    # fully-compliant AG-UI RUN_STARTED events with deterministic run_id,
    # thread_id from formation context, and full metadata extraction.
    # Returns same JSON shape as v4 while routing through AG-UI event pipeline.
    mapped = LifecycleMapper.map_registration(payload)
    EventStream.emit(mapped.type, mapped.data)
  end

  @doc """
  Translates a legacy heartbeat payload to STEP events.

  Heartbeats with status changes emit STEP_STARTED or STEP_FINISHED.
  Regular heartbeats are emitted as CUSTOM events for telemetry tracking.
  """
  @spec translate_heartbeat(map()) :: map()
  def translate_heartbeat(payload) do
    # US-005/US-008 DoD: Delegates to LifecycleMapper.map_heartbeat/1 for
    # proper step lifecycle tracking with step_id, duration_ms computation,
    # and token usage extraction. Returns same JSON shape as v4.
    mapped = LifecycleMapper.map_heartbeat(payload)
    EventStream.emit(mapped.type, mapped.data)
  end

  @doc """
  Translates a legacy notification payload to a CUSTOM event.
  """
  @spec translate_notification(map()) :: map()
  def translate_notification(payload) do
    EventStream.emit(EventType.custom(), %{
      name: "notification",
      agent_id: payload["agent_id"] || payload["session_id"],
      value: %{
        title: payload["title"],
        message: payload["message"],
        level: payload["level"] || "info",
        category: payload["category"],
        action_url: payload["action_url"]
      }
    })
  end

  @doc """
  Translates a legacy tool-use payload to TOOL_CALL events.

  US-011: Uses ToolCallTracker for lifecycle tracking and emits properly
  sequenced events through EventBus instead of direct EventStream calls.
  """
  @spec translate_tool_use(map()) :: [map()]
  def translate_tool_use(payload) do
    alias ApmV5.AgUi.ToolCallTracker

    agent_id = payload["agent_id"] || payload["session_id"]
    tool_name = payload["tool_name"] || payload["tool"] || "unknown"
    tool_call_id = payload["tool_call_id"]

    # track_start publishes TOOL_CALL_START via EventBus
    tc_id = ToolCallTracker.track_start(agent_id, tool_name, tool_call_id)

    # track_args publishes TOOL_CALL_ARGS via EventBus
    if payload["args"] do
      ToolCallTracker.track_args(tc_id, payload["args"])
    end

    # If result data is present, track it (emits TOOL_CALL_RESULT)
    if payload["result"] do
      result_type = payload["result_type"] || "text"
      ToolCallTracker.track_result(tc_id, result_type, payload["result"])
    end

    # track_end publishes TOOL_CALL_END via EventBus
    ToolCallTracker.track_end(tc_id)

    # Return the events for backward compatibility
    [%{type: "TOOL_CALL_START", data: %{agent_id: agent_id, tool_call_id: tc_id, tool_name: tool_name}}]
  end

  @doc """
  Translates a config change to a STATE_DELTA event.

  Emits JSON Patch operations representing the config diff.
  """
  @spec translate_config_change(map(), map()) :: map()
  def translate_config_change(old_config, new_config) do
    delta = compute_delta(old_config, new_config)

    EventStream.emit(EventType.state_delta(), %{
      delta: delta,
      source: "config_reload"
    })
  end

  # -- Private ----------------------------------------------------------------

  defp compute_delta(old_map, new_map) do
    all_keys = MapSet.union(MapSet.new(Map.keys(old_map)), MapSet.new(Map.keys(new_map)))

    Enum.flat_map(all_keys, fn key ->
      old_val = Map.get(old_map, key)
      new_val = Map.get(new_map, key)

      cond do
        is_nil(old_val) and not is_nil(new_val) ->
          [%{"op" => "add", "path" => "/#{key}", "value" => new_val}]

        not is_nil(old_val) and is_nil(new_val) ->
          [%{"op" => "remove", "path" => "/#{key}"}]

        old_val != new_val ->
          [%{"op" => "replace", "path" => "/#{key}", "value" => new_val}]

        true ->
          []
      end
    end)
  end
end
