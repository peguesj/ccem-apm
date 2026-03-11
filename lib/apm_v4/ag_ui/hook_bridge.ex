defmodule ApmV4.AgUi.HookBridge do
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

  alias ApmV4.EventStream

  @doc """
  Translates a legacy registration payload to a RUN_STARTED event.

  Called when POST /api/register receives a new agent/session registration.
  """
  @spec translate_register(map()) :: map()
  def translate_register(payload) do
    agent_id = payload["agent_id"] || payload["session_id"] || "unknown"
    project = payload["project"] || "unknown"

    metadata = %{
      project: project,
      role: payload["role"],
      formation_id: payload["formation_id"],
      formation_role: payload["formation_role"],
      parent_agent_id: payload["parent_agent_id"],
      wave: payload["wave"],
      task_subject: payload["task_subject"],
      original_payload: payload
    }

    EventStream.emit_run_started(agent_id, %{
      thread_id: "thread-#{project}",
      metadata: metadata
    })
  end

  @doc """
  Translates a legacy heartbeat payload to STEP events.

  Heartbeats with status changes emit STEP_STARTED or STEP_FINISHED.
  Regular heartbeats are emitted as CUSTOM events for telemetry tracking.
  """
  @spec translate_heartbeat(map()) :: map()
  def translate_heartbeat(payload) do
    agent_id = payload["agent_id"] || payload["session_id"]
    status = payload["status"]

    case status do
      "active" ->
        EventStream.emit("STEP_STARTED", %{
          agent_id: agent_id,
          step_name: payload["task_subject"] || "heartbeat",
          metadata: strip_nils(payload)
        })

      status when status in ["completed", "done", "finished"] ->
        EventStream.emit("STEP_FINISHED", %{
          agent_id: agent_id,
          step_name: payload["task_subject"] || "heartbeat",
          metadata: strip_nils(payload)
        })

      _ ->
        EventStream.emit("CUSTOM", %{
          name: "heartbeat",
          agent_id: agent_id,
          value: strip_nils(payload)
        })
    end
  end

  @doc """
  Translates a legacy notification payload to a CUSTOM event.
  """
  @spec translate_notification(map()) :: map()
  def translate_notification(payload) do
    EventStream.emit("CUSTOM", %{
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

  Emits the full tool call lifecycle: START -> ARGS -> END.
  """
  @spec translate_tool_use(map()) :: [map()]
  def translate_tool_use(payload) do
    agent_id = payload["agent_id"] || payload["session_id"]
    run_id = payload["run_id"] || "run-#{agent_id}"
    tool_name = payload["tool_name"] || payload["tool"] || "unknown"
    tool_call_id = payload["tool_call_id"]

    start_event = EventStream.emit_tool_call_start(agent_id, run_id, tool_name, tool_call_id)
    tc_id = start_event.data[:tool_call_id]

    args_event =
      if payload["args"] do
        EventStream.emit_tool_call_args(agent_id, run_id, tc_id, payload["args"])
      end

    end_event = EventStream.emit_tool_call_end(agent_id, run_id, tc_id)

    Enum.reject([start_event, args_event, end_event], &is_nil/1)
  end

  @doc """
  Translates a config change to a STATE_DELTA event.

  Emits JSON Patch operations representing the config diff.
  """
  @spec translate_config_change(map(), map()) :: map()
  def translate_config_change(old_config, new_config) do
    delta = compute_delta(old_config, new_config)

    EventStream.emit("STATE_DELTA", %{
      delta: delta,
      source: "config_reload"
    })
  end

  # -- Private ----------------------------------------------------------------

  defp strip_nils(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

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
