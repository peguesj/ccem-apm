defmodule ApmV5.AgUi.HookBridge do
  @moduledoc """
  Translates legacy CCEM APM hook payloads into AG-UI protocol events.

  Legacy hooks emit JSON payloads to endpoints like /api/register, /api/heartbeat,
  /api/notify, /api/tool-use. This bridge converts those payloads into proper
  AG-UI event types and emits them through the EventStream.

  ## Mapping

  | Legacy Endpoint      | AG-UI Event Type                          |
  |---------------------|-------------------------------------------|
  | POST /api/register  | RUN_STARTED                               |
  | POST /api/heartbeat | STEP_STARTED/FINISHED (status change)     |
  | POST /api/notify    | Semantic routing by event_type/category   |
  | POST /api/tool-use  | TOOL_CALL_START/ARGS/END/RESULT           |
  | Config reload       | STATE_DELTA                               |

  ## Notification → AG-UI Semantic Routing

  Notifications are routed by their `event_type` field first, then by `category`:

  | Notification event_type/category     | AG-UI Event Type         |
  |--------------------------------------|--------------------------|
  | spawn / agent_spawned                | RUN_STARTED              |
  | task_complete / agent_complete       | RUN_FINISHED             |
  | task_fail / agent_failed / error     | RUN_ERROR                |
  | upm_wave_start / squadron_started    | STEP_STARTED             |
  | upm_wave_complete / squadron_complete| STEP_FINISHED            |
  | agent_input_required                 | TEXT_MESSAGE_START+CONTENT+END |
  | upm_plan_complete / formation_*      | CUSTOM (semantic name)   |
  | default                              | CUSTOM (semantic name)   |
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
  Translates a legacy notification payload to the appropriate AG-UI event type.

  Routes semantically based on `event_type` field (formation/UPM lifecycle events)
  then `category` field, then falls back to CUSTOM with a semantic name.

  ## Semantic routing:
  - spawn/agent_spawned       → RUN_STARTED
  - task_complete/agent_complete → RUN_FINISHED
  - task_fail/agent_failed/error → RUN_ERROR
  - upm_wave_start/squadron_started → STEP_STARTED
  - upm_wave_complete/squadron_complete → STEP_FINISHED
  - agent_input_required      → TEXT_MESSAGE_START + CONTENT + END
  - all others                → CUSTOM with semantic name
  """
  @spec translate_notification(map()) :: map()
  def translate_notification(payload) do
    agent_id = payload["agent_id"] || payload["session_id"]
    event_type = payload["event_type"] || payload["type"]
    category = payload["category"]

    cond do
      # Lifecycle: agent/run started
      event_type in ["spawn", "agent_spawned", "run_started"] or
        (category == "agent" and event_type == "spawn") ->
        EventStream.emit(EventType.run_started(), %{
          agent_id: agent_id,
          run_id: payload["formation_id"] || payload["agent_id"] || "unknown",
          thread_id: payload["session_id"] || agent_id || "unknown",
          metadata: notification_metadata(payload)
        })

      # Lifecycle: agent/run finished
      event_type in ["task_complete", "agent_complete", "formation_complete", "run_finished"] ->
        EventStream.emit(EventType.run_finished(), %{
          agent_id: agent_id,
          run_id: payload["formation_id"] || agent_id || "unknown",
          thread_id: payload["session_id"] || agent_id || "unknown",
          result: payload["payload"] || payload["message"],
          metadata: notification_metadata(payload)
        })

      # Lifecycle: agent/run error
      event_type in ["task_fail", "agent_failed", "run_error", "upm_kill_criteria"] or
        (payload["type"] == "error" and is_nil(event_type)) ->
        EventStream.emit(EventType.run_error(), %{
          agent_id: agent_id,
          message: payload["message"] || "Agent failed",
          code: event_type || "unknown_error",
          metadata: notification_metadata(payload)
        })

      # Step started: wave/squadron begins
      event_type in ["upm_wave_start", "squadron_started", "swarm_spawned", "step_started"] ->
        step_name = payload["title"] || event_type
        EventStream.emit(EventType.step_started(), %{
          agent_id: agent_id,
          step_name: step_name,
          wave: payload["wave"] || get_in(payload, ["payload", "wave"]),
          formation_id: payload["formation_id"],
          metadata: notification_metadata(payload)
        })

      # Step finished: wave/squadron complete
      event_type in ["upm_wave_complete", "squadron_complete", "swarm_complete", "step_finished"] ->
        step_name = payload["title"] || event_type
        EventStream.emit(EventType.step_finished(), %{
          agent_id: agent_id,
          step_name: step_name,
          wave: payload["wave"] || get_in(payload, ["payload", "wave"]),
          formation_id: payload["formation_id"],
          metadata: notification_metadata(payload)
        })

      # Text: agent waiting for input → present as text message from agent
      event_type in ["agent_input_required", "input_required"] ->
        message_id = "msg-#{agent_id}-#{System.system_time(:millisecond)}"
        msg = payload["message"] || payload["title"] || "Input required"
        EventStream.emit(EventType.text_message_start(), %{
          agent_id: agent_id,
          message_id: message_id,
          role: "assistant"
        })
        EventStream.emit(EventType.text_message_content(), %{
          agent_id: agent_id,
          message_id: message_id,
          delta: msg
        })
        EventStream.emit(EventType.text_message_end(), %{
          agent_id: agent_id,
          message_id: message_id
        })

      # Default: emit CUSTOM with semantic name (title, category preserved)
      true ->
        semantic_name = event_type || category || "notification"
        EventStream.emit(EventType.custom(), %{
          name: semantic_name,
          agent_id: agent_id,
          value: %{
            title: payload["title"],
            message: payload["message"],
            level: payload["level"] || payload["type"] || "info",
            category: category,
            event_type: event_type,
            formation_id: payload["formation_id"],
            action_url: payload["action_url"]
          }
        })
    end
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

  # Builds a compact metadata map from notification payload for event augmentation.
  defp notification_metadata(payload) do
    %{}
    |> maybe_put("formation_id", payload["formation_id"])
    |> maybe_put("formation_role", payload["formation_role"])
    |> maybe_put("wave", payload["wave"] || get_in(payload, ["payload", "wave"]))
    |> maybe_put("task_subject", payload["task_subject"])
    |> maybe_put("project", payload["project"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
