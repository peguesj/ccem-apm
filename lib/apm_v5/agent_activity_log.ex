defmodule ApmV5.AgentActivityLog do
  @max_entries 200

  @moduledoc """
  Ring-buffer activity log for agent lifecycle events.

  Subscribes to EventBus topics (lifecycle, tool, thinking, text) and
  maintains the last #{@max_entries} entries in newest-first order.
  Broadcasts each new entry via Phoenix.PubSub on the "apm:activity_log"
  topic so LiveViews can stream updates without polling.

  ## Client API
  - `list_recent/1`   — last N entries (default 50)
  - `get_agent_log/2` — last N entries for one agent_id (default 20)
  - `clear/0`         — flush all entries (test utility)
  """

  use GenServer

  require Logger

  alias ApmV5.AgUi.EventBus

  # -- Client API -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the last `limit` activity log entries (newest first)."
  @spec list_recent(pos_integer()) :: [map()]
  def list_recent(limit \\ 50) do
    GenServer.call(__MODULE__, {:list_recent, limit})
  end

  @doc "Returns the last `limit` entries for a specific agent."
  @spec get_agent_log(String.t(), pos_integer()) :: [map()]
  def get_agent_log(agent_id, limit \\ 20) do
    GenServer.call(__MODULE__, {:get_agent_log, agent_id, limit})
  end

  @doc "Clears all entries (test utility)."
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # -- GenServer Callbacks ----------------------------------------------------

  @impl true
  def init(_opts) do
    EventBus.subscribe("lifecycle:*")
    EventBus.subscribe("tool:*")
    EventBus.subscribe("thinking:*")
    EventBus.subscribe("text:*")

    {:ok, %{entries: []}}
  end

  @impl true
  def handle_call({:list_recent, limit}, _from, state) do
    {:reply, Enum.take(state.entries, limit), state}
  end

  def handle_call({:get_agent_log, agent_id, limit}, _from, state) do
    filtered =
      state.entries
      |> Enum.filter(&(&1.agent_id == agent_id))
      |> Enum.take(limit)

    {:reply, filtered, state}
  end

  def handle_call(:clear, _from, _state) do
    {:reply, :ok, %{entries: []}}
  end

  @impl true
  def handle_info({:event_bus, _topic, event}, state) do
    new_state = maybe_log_event(event, state)
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private ----------------------------------------------------------------

  defp maybe_log_event(%{type: type, data: data}, state) when is_map(data) do
    agent_id =
      Map.get(data, "agentId") ||
        Map.get(data, "agent_id") ||
        Map.get(data, :agentId) ||
        Map.get(data, :agent_id) ||
        "unknown"

    entry = %{
      id: System.unique_integer([:positive, :monotonic]) |> to_string(),
      agent_id: agent_id,
      event_type: type,
      description: describe(type, data),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      metadata: extract_metadata(type, data)
    }

    Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:activity_log", {:activity_log_entry, entry})

    new_entries = [entry | state.entries] |> Enum.take(@max_entries)
    %{state | entries: new_entries}
  end

  defp maybe_log_event(_event, state), do: state

  @spec describe(String.t(), map()) :: String.t()
  defp describe("TOOL_CALL_START", data) do
    tool = Map.get(data, "tool_name") || Map.get(data, :tool_name) || "unknown"
    "Using tool: #{tool}"
  end

  defp describe("TOOL_CALL_END", data) do
    tool = Map.get(data, "tool_name") || Map.get(data, :tool_name) || "unknown"
    "Finished tool: #{tool}"
  end

  defp describe("THINKING_START", _data), do: "Thinking..."
  defp describe("THINKING_END", _data), do: "Thinking complete"
  defp describe("TEXT_MESSAGE_START", _data), do: "Composing response"
  defp describe("TEXT_MESSAGE_END", _data), do: "Response complete"

  defp describe("STEP_STARTED", data) do
    step = Map.get(data, "step_name") || Map.get(data, :step_name) || "unknown"
    "Started step: #{step}"
  end

  defp describe("STEP_FINISHED", data) do
    step = Map.get(data, "step_name") || Map.get(data, :step_name) || "unknown"
    "Step complete: #{step}"
  end

  defp describe("RUN_STARTED", _data), do: "Agent started"
  defp describe("RUN_FINISHED", _data), do: "Agent finished"
  defp describe("RUN_ERROR", _data), do: "Agent error"
  defp describe(event_type, _data), do: event_type

  @spec extract_metadata(String.t(), map()) :: map()
  defp extract_metadata(type, data) when type in ["TOOL_CALL_START", "TOOL_CALL_END"] do
    %{tool_name: Map.get(data, "tool_name") || Map.get(data, :tool_name)}
  end

  defp extract_metadata(type, data) when type in ["STEP_STARTED", "STEP_FINISHED"] do
    %{step_name: Map.get(data, "step_name") || Map.get(data, :step_name)}
  end

  defp extract_metadata(_type, _data), do: %{}
end
