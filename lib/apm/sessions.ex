defmodule Apm.Sessions do
  @moduledoc """
  Context facade for the Investigate / sessions surface (v11 IA).

  Delegates to `Apm.SessionManager` and enriches session maps with
  computed fields needed by `InvestigateSessionLive`.

  PubSub topic: `"apm:sessions"` — broadcast on any session list change.
  Per-session topic: `"apm:sessions:" <> session_id` — pushed by
  `Apm.AgUi.ToolCallTracker` when tool calls are recorded.
  """

  alias Apm.SessionManager

  @pubsub_topic "apm:sessions"

  @doc "The canonical PubSub topic for the session list."
  @spec pubsub_topic() :: String.t()
  def pubsub_topic, do: @pubsub_topic

  @doc "Per-session PubSub topic for live tool-call updates."
  @spec session_topic(String.t()) :: String.t()
  def session_topic(session_id), do: "apm:sessions:#{session_id}"

  @doc "Return all known sessions (active + historical)."
  @spec list(keyword()) :: [map()]
  def list(_opts \\ []) do
    SessionManager.list_sessions()
  end

  @doc "Return a single session by id, or nil."
  @spec get(String.t()) :: map() | nil
  def get(session_id) do
    SessionManager.get_session(session_id)
  end

  @doc "Return a session with deep context (agents, ports, skills, CLAUDE.md preview)."
  @spec get_with_context(String.t()) :: map() | nil
  def get_with_context(session_id) do
    SessionManager.get_session_with_context(session_id)
  end

  @doc """
  Derives a metrics map from a session for the 5-up metric strip in
  `InvestigateSessionLive`.

  Returns:
    %{
      duration_s: integer() | nil,
      tokens_in:  integer(),
      tokens_out: integer(),
      tool_calls: integer(),
      cost_usd:   float() | nil
    }
  """
  @spec metrics(map()) :: map()
  def metrics(session) when is_map(session) do
    %{
      duration_s: compute_duration(session),
      tokens_in: Map.get(session, :tokens_in, 0),
      tokens_out: Map.get(session, :tokens_out, 0),
      tool_calls: Map.get(session, :tool_call_count, 0),
      cost_usd: Map.get(session, :cost_usd)
    }
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp compute_duration(%{started_at: started, ended_at: ended})
       when not is_nil(started) and not is_nil(ended) do
    case {started, ended} do
      {s, e} when is_struct(s, DateTime) and is_struct(e, DateTime) ->
        DateTime.diff(e, s, :second)

      _ ->
        nil
    end
  end

  defp compute_duration(%{started_at: started}) when not is_nil(started) do
    case started do
      s when is_struct(s, DateTime) -> DateTime.diff(DateTime.utc_now(), s, :second)
      _ -> nil
    end
  end

  defp compute_duration(_), do: nil
end
