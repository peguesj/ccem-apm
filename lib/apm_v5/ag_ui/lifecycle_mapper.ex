defmodule ApmV5.AgUi.LifecycleMapper do
  @moduledoc """
  Maps agent lifecycle events to fully-compliant AG-UI protocol events.

  Enriches POST /api/register payloads into RUN_STARTED events,
  heartbeats into STEP_STARTED/STEP_FINISHED events, and completion
  signals into RUN_FINISHED/RUN_ERROR events.

  ## US-004 Acceptance Criteria (DoD):
  - map_registration/1 generates RUN_STARTED with run_id, thread_id, metadata
  - Deterministic run_id from agent_id + registration timestamp
  - thread_id extracted from project name or formation_id
  - Metadata includes formation_role, wave, task_subject, parent_agent_id
  - Returns fully-structured AG-UI RUN_STARTED event map
  - HookBridge.translate_register/1 delegates to this module

  ## US-005 Acceptance Criteria (DoD):
  - map_heartbeat/1 generates STEP_STARTED with unique step_id when status is 'active'
  - STEP_FINISHED events include duration_ms from matching STEP_STARTED timestamp
  - Step tracking stored in ETS :ag_ui_step_tracker keyed by {agent_id, step_name}
  - Token usage extracted from heartbeat payload
  - Heartbeats without status changes emit CUSTOM 'heartbeat' event

  ## US-006 Acceptance Criteria (DoD):
  - map_completion/2 generates RUN_FINISHED with run_id, duration_ms, summary metrics
  - map_error/2 generates RUN_ERROR with error message and run_id
  - Run start times tracked in ETS :ag_ui_run_tracker keyed by agent_id
  - AgentRegistry.update_status triggers RUN_FINISHED/RUN_ERROR
  - Summary metrics: steps_completed, tool_calls_made, errors_encountered, total_tokens
  """

  alias AgUi.Core.Events.EventType

  @run_tracker :ag_ui_run_tracker
  @step_tracker :ag_ui_step_tracker

  # -- Public API -------------------------------------------------------------

  @doc """
  Initialize ETS tables for run and step tracking.
  Called from EventBus or Application startup.
  """
  @spec init_tables() :: :ok
  def init_tables do
    if :ets.whereis(@run_tracker) == :undefined do
      :ets.new(@run_tracker, [:named_table, :set, :public, read_concurrency: true])
    end

    if :ets.whereis(@step_tracker) == :undefined do
      :ets.new(@step_tracker, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Maps a legacy registration payload to a fully-compliant AG-UI RUN_STARTED event.

  Generates deterministic run_id, extracts thread_id from context,
  and populates metadata from formation/UPM context.
  """
  @spec map_registration(map()) :: map()
  def map_registration(payload) do
    agent_id = payload["agent_id"] || payload["session_id"] || "unknown"
    project = payload["project"] || "unknown"
    now = DateTime.utc_now()

    run_id = generate_run_id(agent_id, now)
    thread_id = payload["formation_id"] || "thread-#{project}"

    # Track run start time
    :ets.insert(@run_tracker, {agent_id, %{
      run_id: run_id,
      started_at: now,
      steps_completed: 0,
      tool_calls_made: 0,
      errors_encountered: 0,
      total_tokens: 0
    }})

    metadata = %{
      project: project,
      formation_role: payload["formation_role"],
      wave: payload["wave"],
      task_subject: payload["task_subject"],
      parent_agent_id: payload["parent_agent_id"],
      formation_id: payload["formation_id"],
      role: payload["role"],
      original_payload: payload
    }

    %{
      type: EventType.run_started(),
      data: %{
        agent_id: agent_id,
        run_id: run_id,
        thread_id: thread_id,
        metadata: metadata
      }
    }
  end

  @doc """
  Maps a heartbeat payload to appropriate AG-UI step lifecycle events.

  Active status -> STEP_STARTED with unique step_id.
  Completed/done/finished status -> STEP_FINISHED with duration_ms.
  Other status -> CUSTOM heartbeat event.
  """
  @spec map_heartbeat(map()) :: map()
  def map_heartbeat(payload) do
    agent_id = payload["agent_id"] || payload["session_id"]
    status = payload["status"]
    step_name = payload["task_subject"] || payload["message"] || "heartbeat"

    token_metadata = extract_token_usage(payload)

    case status do
      "active" ->
        step_id = generate_step_id()
        now = DateTime.utc_now()
        :ets.insert(@step_tracker, {{agent_id, step_name}, %{step_id: step_id, started_at: now}})
        update_run_steps(agent_id, token_metadata)

        %{
          type: EventType.step_started(),
          data: %{
            agent_id: agent_id,
            step_id: step_id,
            step_name: step_name,
            metadata: Map.merge(strip_nils(payload), token_metadata)
          }
        }

      status when status in ["completed", "done", "finished"] ->
        {step_id, duration_ms} = resolve_step_completion(agent_id, step_name)
        update_run_steps(agent_id, token_metadata)

        %{
          type: EventType.step_finished(),
          data: %{
            agent_id: agent_id,
            step_id: step_id,
            step_name: step_name,
            duration_ms: duration_ms,
            metadata: Map.merge(strip_nils(payload), token_metadata)
          }
        }

      _ ->
        %{
          type: EventType.custom(),
          data: %{
            name: "heartbeat",
            agent_id: agent_id,
            value: Map.merge(strip_nils(payload), token_metadata)
          }
        }
    end
  end

  @doc """
  Maps agent completion to a RUN_FINISHED event with summary metrics.
  """
  @spec map_completion(String.t(), map()) :: map()
  def map_completion(agent_id, metadata \\ %{}) do
    {run_id, duration_ms, summary} = resolve_run_completion(agent_id)

    %{
      type: EventType.run_finished(),
      data: %{
        agent_id: agent_id,
        run_id: run_id,
        duration_ms: duration_ms,
        summary: summary,
        metadata: metadata
      }
    }
  end

  @doc """
  Maps agent error to a RUN_ERROR event.
  """
  @spec map_error(String.t(), map()) :: map()
  def map_error(agent_id, error_data \\ %{}) do
    {run_id, duration_ms, summary} = resolve_run_completion(agent_id)

    # Increment error count
    update_run_errors(agent_id)

    %{
      type: EventType.run_error(),
      data: %{
        agent_id: agent_id,
        run_id: run_id,
        duration_ms: duration_ms,
        message: error_data[:message] || error_data["message"] || "Unknown error",
        stack_trace: error_data[:stack_trace] || error_data["stack_trace"],
        summary: summary
      }
    }
  end

  @doc """
  Maps thinking/reasoning output to THINKING events.

  ## US-044 DoD: Generates THINKING_START/THINKING_END + TEXT_MESSAGE_* events.
  """
  @spec map_thinking(String.t(), map()) :: map()
  def map_thinking(agent_id, payload) do
    run_id = get_run_id(agent_id)
    action = payload["action"] || "start"

    case action do
      "start" ->
        %{type: "THINKING_START", data: %{agent_id: agent_id, run_id: run_id}}

      "end" ->
        %{type: "THINKING_END", data: %{agent_id: agent_id, run_id: run_id}}

      _ ->
        %{type: EventType.custom(), data: %{name: "thinking", agent_id: agent_id, value: payload}}
    end
  end

  # -- Private ----------------------------------------------------------------

  defp generate_run_id(agent_id, %DateTime{} = dt) do
    hash = :crypto.hash(:sha256, "#{agent_id}:#{DateTime.to_unix(dt, :millisecond)}")
    "run-" <> Base.encode16(binary_part(hash, 0, 8), case: :lower)
  end

  defp generate_step_id do
    "step-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp extract_token_usage(payload) do
    %{
      input_tokens: payload["input_tokens"] || get_in_nested(payload, ["metadata", "input_tokens"]),
      output_tokens: payload["output_tokens"] || get_in_nested(payload, ["metadata", "output_tokens"]),
      cache_read: payload["cache_read"] || get_in_nested(payload, ["metadata", "cache_read"]),
      cache_write: payload["cache_write"] || get_in_nested(payload, ["metadata", "cache_write"])
    }
    |> strip_nils()
  end

  defp get_in_nested(map, keys) when is_map(map) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case acc do
        %{^key => val} -> {:cont, val}
        _ -> {:halt, nil}
      end
    end)
  end

  defp get_in_nested(_, _), do: nil

  defp resolve_step_completion(agent_id, step_name) do
    case :ets.lookup(@step_tracker, {agent_id, step_name}) do
      [{{^agent_id, ^step_name}, %{step_id: step_id, started_at: started_at}}] ->
        duration_ms = DateTime.diff(DateTime.utc_now(), started_at, :millisecond)
        :ets.delete(@step_tracker, {agent_id, step_name})
        {step_id, duration_ms}

      [] ->
        {generate_step_id(), 0}
    end
  end

  defp resolve_run_completion(agent_id) do
    case :ets.lookup(@run_tracker, agent_id) do
      [{^agent_id, tracker}] ->
        duration_ms = DateTime.diff(DateTime.utc_now(), tracker.started_at, :millisecond)

        summary = %{
          steps_completed: tracker.steps_completed,
          tool_calls_made: tracker.tool_calls_made,
          errors_encountered: tracker.errors_encountered,
          total_tokens: tracker.total_tokens
        }

        :ets.delete(@run_tracker, agent_id)
        {tracker.run_id, duration_ms, summary}

      [] ->
        {"run-unknown", 0, %{steps_completed: 0, tool_calls_made: 0, errors_encountered: 0, total_tokens: 0}}
    end
  end

  defp get_run_id(agent_id) do
    case :ets.lookup(@run_tracker, agent_id) do
      [{^agent_id, %{run_id: run_id}}] -> run_id
      [] -> "run-#{agent_id}"
    end
  end

  defp update_run_steps(agent_id, token_meta) do
    case :ets.lookup(@run_tracker, agent_id) do
      [{^agent_id, tracker}] ->
        tokens = (token_meta[:input_tokens] || 0) + (token_meta[:output_tokens] || 0)

        :ets.insert(@run_tracker, {agent_id, %{tracker |
          steps_completed: tracker.steps_completed + 1,
          total_tokens: tracker.total_tokens + tokens
        }})

      [] ->
        :ok
    end
  end

  defp update_run_errors(agent_id) do
    case :ets.lookup(@run_tracker, agent_id) do
      [{^agent_id, tracker}] ->
        :ets.insert(@run_tracker, {agent_id, %{tracker |
          errors_encountered: tracker.errors_encountered + 1
        }})

      [] ->
        :ok
    end
  end

  defp strip_nils(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end
end
