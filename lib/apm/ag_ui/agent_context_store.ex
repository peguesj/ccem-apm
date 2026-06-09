defmodule Apm.AgUi.AgentContextStore do
  @moduledoc """
  Real-time contextual state store for agent inspector enrichment.

  Subscribes to AG-UI EventBus topics and maintains a per-agent context map
  in ETS. Each agent entry tracks:
  - current_event_type: the most recent AG-UI event type (e.g. "TOOL_CALL_START")
  - current_tool: tool name when in a tool-call lifecycle
  - activity_label: human-readable "Thinking…", "Running: Bash", "Writing: foo.ex"
  - recent_events: last 5 AG-UI events with timestamps
  - started_at: wall-clock ISO-8601 registration time (for running time display)
  - updated_at: wall-clock ISO-8601 last event time

  PubSub topic "apm:agent_context" is broadcast on every context update so
  DashboardLive can push_event to the client.
  """

  use GenServer

  require Logger

  alias Apm.AgUi.EventBus

  @table :ag_ui_agent_context
  @max_recent_events 5

  # -- Client API -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns current context for a specific agent."
  @spec get_context(String.t()) :: map() | nil
  def get_context(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, ctx}] -> ctx
      [] -> nil
    end
  end

  @doc "Returns all agent contexts as a map of agent_id => context."
  @spec list_contexts() :: map()
  def list_contexts do
    :ets.tab2list(@table)
    |> Map.new(fn {id, ctx} -> {id, ctx} end)
  end

  @doc "Returns contextual activity label for an agent (for fleet card display)."
  @spec activity_label(String.t()) :: String.t()
  def activity_label(agent_id) do
    case get_context(agent_id) do
      nil -> "Idle"
      ctx -> Map.get(ctx, :activity_label, "Idle")
    end
  end

  @doc "Returns recent AG-UI events (last N) for an agent."
  @spec recent_events(String.t(), non_neg_integer()) :: [map()]
  def recent_events(agent_id, limit \\ @max_recent_events) do
    case get_context(agent_id) do
      nil -> []
      ctx -> ctx |> Map.get(:recent_events, []) |> Enum.take(limit)
    end
  end

  # -- GenServer Callbacks ----------------------------------------------------

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    EventBus.subscribe("lifecycle:*")
    EventBus.subscribe("tool:*")
    EventBus.subscribe("thinking:*")
    EventBus.subscribe("text:*")
    EventBus.subscribe("activity:*")
    EventBus.subscribe("special:custom")

    {:ok, %{}}
  end

  @impl true
  def handle_info({:event_bus, _topic, event}, state) do
    agent_id = extract_agent_id(event)

    if agent_id do
      update_context(agent_id, event)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private ----------------------------------------------------------------

  defp extract_agent_id(event) do
    Map.get(event, :agent_id) || Map.get(event, "agent_id")
  end

  defp update_context(agent_id, event) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    event_type = Map.get(event, :type) || Map.get(event, "type") || "CUSTOM"
    tool_name = get_in(event, [:data, :tool_name]) || get_in(event, ["data", "tool_name"])

    existing =
      case :ets.lookup(@table, agent_id) do
        [{^agent_id, ctx}] -> ctx
        [] -> %{started_at: now, recent_events: []}
      end

    label = activity_label_for(event_type, tool_name, event)

    recent =
      [
        %{type: event_type, tool: tool_name, ts: now, label: label}
        | Map.get(existing, :recent_events, [])
      ]
      |> Enum.take(@max_recent_events)

    updated = %{
      agent_id: agent_id,
      current_event_type: event_type,
      current_tool: tool_name,
      activity_label: label,
      recent_events: recent,
      started_at: Map.get(existing, :started_at, now),
      updated_at: now
    }

    :ets.insert(@table, {agent_id, updated})

    Phoenix.PubSub.broadcast(
      Apm.PubSub,
      "apm:agent_context",
      {:agent_context_updated, agent_id, updated}
    )
  end

  # Maps AG-UI event type + tool name to a human-readable activity label.
  defp activity_label_for("RUN_STARTED", _tool, _event), do: "Starting..."
  defp activity_label_for("RUN_FINISHED", _tool, _event), do: "Completed"

  defp activity_label_for("RUN_ERROR", _tool, event) do
    msg = get_in(event, [:data, :message]) || get_in(event, ["data", "message"]) || "error"
    "Error: #{truncate(msg, 30)}"
  end

  defp activity_label_for("STEP_STARTED", _tool, event) do
    step = get_in(event, [:data, :step_name]) || get_in(event, ["data", "step_name"]) || "step"
    "Step: #{truncate(step, 30)}"
  end

  defp activity_label_for("STEP_FINISHED", _tool, event) do
    step = get_in(event, [:data, :step_name]) || get_in(event, ["data", "step_name"]) || "step"
    "Done: #{truncate(step, 30)}"
  end

  defp activity_label_for("TOOL_CALL_START", tool, _event) when is_binary(tool),
    do: "Running: #{tool}"

  defp activity_label_for("TOOL_CALL_START", _tool, _event), do: "Running tool..."

  defp activity_label_for("TOOL_CALL_ARGS", tool, _event) when is_binary(tool),
    do: "Running: #{tool}"

  defp activity_label_for("TOOL_CALL_ARGS", _tool, _event), do: "Running tool..."
  defp activity_label_for("TOOL_CALL_END", _tool, _event), do: "Tool done"
  defp activity_label_for("TOOL_CALL_RESULT", _tool, _event), do: "Processing result..."
  defp activity_label_for("TEXT_MESSAGE_START", _tool, _event), do: "Writing..."

  defp activity_label_for("TEXT_MESSAGE_CONTENT", _tool, event) do
    delta = get_in(event, [:data, :delta]) || get_in(event, ["data", "delta"]) || ""
    "Writing: #{truncate(delta, 40)}"
  end

  defp activity_label_for("TEXT_MESSAGE_END", _tool, _event), do: "Message sent"
  defp activity_label_for("THINKING_START", _tool, _event), do: "Thinking..."

  defp activity_label_for("THINKING_CONTENT", _tool, event) do
    delta = get_in(event, [:data, :delta]) || get_in(event, ["data", "delta"]) || ""
    "Thinking: #{truncate(delta, 40)}"
  end

  defp activity_label_for("THINKING_END", _tool, _event), do: "Thought complete"
  defp activity_label_for("STATE_DELTA", _tool, _event), do: "State update"

  defp activity_label_for("CUSTOM", _tool, event) do
    name =
      get_in(event, [:data, :name]) || get_in(event, ["data", "name"]) ||
        get_in(event, [:name]) || get_in(event, ["name"]) || "custom"

    "Event: #{truncate(name, 30)}"
  end

  defp activity_label_for(type, _tool, _event), do: truncate(type, 40)

  defp truncate(str, max) when is_binary(str) and byte_size(str) > max,
    do: String.slice(str, 0, max) <> "..."

  defp truncate(str, _) when is_binary(str), do: str
  defp truncate(other, _), do: inspect(other)
end
