defmodule Apm.ToolCalls do
  @moduledoc """
  Context facade for tool-call data used by the Investigate section (v11 IA).

  Delegates to `Apm.AgUi.ToolCallTracker` (ETS-backed) for active/recent
  tool calls, and to `Apm.Auth.ApprovalAuditLog` for audit cross-references.

  Data shape returned by `for_session/1`:
    %{
      id:          String.t(),
      session_id:  String.t(),
      agent_id:    String.t(),
      tool_name:   String.t(),
      status:      :pending | :running | :completed | :error,
      duration_ms: integer() | nil,
      args:        map(),
      result:      term() | nil,
      error:       String.t() | nil,
      started_at:  DateTime.t() | nil,
      ended_at:    DateTime.t() | nil
    }
  """

  alias Apm.AgUi.ToolCallTracker
  alias Apm.Auth.ApprovalAuditLog

  @doc "Return all tool calls associated with a session."
  @spec for_session(String.t()) :: [map()]
  def for_session(session_id) do
    try do
      ToolCallTracker.list_by_agent(session_id)
    rescue
      _ ->
        # Fallback: scan all active calls
        try do
          ToolCallTracker.list_active()
          |> Enum.filter(&(&1[:session_id] == session_id or &1[:agent_id] == session_id))
        rescue
          _ -> []
        end
    end
  end

  @doc "Return a single tool call by id, or nil."
  @spec get(String.t()) :: map() | nil
  def get(tool_call_id) do
    try do
      ToolCallTracker.get(tool_call_id)
    rescue
      _ -> nil
    end
  end

  @doc """
  Return audit log entries cross-referenced for a tool call.
  Looks up approval and auth audit entries matching the tool call id.
  """
  @spec audit_for(String.t()) :: [map()]
  def audit_for(tool_call_id) do
    try do
      ApprovalAuditLog.list_entries()
      |> Enum.filter(fn entry ->
        Map.get(entry, :tool_call_id) == tool_call_id or
          Map.get(entry, :request_id) == tool_call_id
      end)
    rescue
      _ -> []
    end
  end

  @doc """
  Build timeline-compatible lane/event maps from a list of tool calls.

  Returns `{lanes, events}` where:
  - lanes: distinct tool names as lanes
  - events: one event per tool call, positioned by timestamp
  """
  @spec to_timeline([ map()]) :: {[map()], [map()]}
  def to_timeline(tool_calls) when is_list(tool_calls) do
    lanes =
      tool_calls
      |> Enum.map(& &1[:tool_name] || "unknown")
      |> Enum.uniq()
      |> Enum.map(fn name -> %{id: name, label: name, color: nil} end)

    events =
      Enum.map(tool_calls, fn tc ->
        start_ms = to_epoch_ms(tc[:started_at])
        end_ms = to_epoch_ms(tc[:ended_at])
        tone = status_to_tone(tc[:status])

        %{
          id: tc[:id] || System.unique_integer([:positive]) |> to_string(),
          lane_id: tc[:tool_name] || "unknown",
          label: tc[:tool_name] || "tool",
          start_ms: start_ms,
          end_ms: end_ms,
          tone: tone
        }
      end)

    {lanes, events}
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp to_epoch_ms(nil), do: System.system_time(:millisecond)
  defp to_epoch_ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)
  defp to_epoch_ms(ts) when is_integer(ts), do: ts
  defp to_epoch_ms(_), do: System.system_time(:millisecond)

  defp status_to_tone(:completed), do: "success"
  defp status_to_tone(:error), do: "error"
  defp status_to_tone(:running), do: "info"
  defp status_to_tone(:pending), do: "warning"
  defp status_to_tone(_), do: "neutral"
end
