defmodule ApmV5.EventStream do
  @moduledoc """
  GenServer managing AG-UI protocol event streaming.

  Maintains a monotonically increasing sequence counter, stores recent events,
  and broadcasts to subscribers via PubSub. Events follow the AG-UI spec:
  TEXT_MESSAGE_START, TEXT_MESSAGE_CONTENT, TEXT_MESSAGE_END,
  TOOL_CALL_START, TOOL_CALL_ARGS, TOOL_CALL_END,
  STATE_SNAPSHOT, RUN_STARTED, RUN_FINISHED.
  """

  use GenServer

  @pubsub ApmV5.PubSub
  @topic "ag_ui:events"
  @max_events 500

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Emit an AG-UI event. Returns the event with sequence number assigned."
  @spec emit(String.t(), map()) :: map()
  def emit(type, data \\ %{}) do
    GenServer.call(__MODULE__, {:emit, type, data})
  end

  @doc "Get recent events, optionally filtered by agent_id. Returns newest first."
  @spec get_events(String.t() | nil, non_neg_integer()) :: [map()]
  def get_events(agent_id \\ nil, limit \\ 100) do
    GenServer.call(__MODULE__, {:get_events, agent_id, limit})
  end

  @doc "Get the PubSub topic for subscribing to AG-UI events."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribe the calling process to AG-UI events."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc "Clear all stored events and reset the sequence counter."
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # --- Convenience emitters for AG-UI event types ---

  @doc "Emit RUN_STARTED when an agent registers."
  def emit_run_started(agent_id, metadata \\ %{}) do
    run_id = generate_run_id()
    thread_id = Map.get(metadata, :thread_id, "thread-#{agent_id}")

    emit("RUN_STARTED", %{
      agent_id: agent_id,
      run_id: run_id,
      thread_id: thread_id,
      metadata: metadata
    })
  end

  @doc "Emit RUN_FINISHED when an agent completes."
  def emit_run_finished(agent_id, run_id, metadata \\ %{}) do
    emit("RUN_FINISHED", %{
      agent_id: agent_id,
      run_id: run_id,
      thread_id: Map.get(metadata, :thread_id, "thread-#{agent_id}"),
      metadata: metadata
    })
  end

  @doc "Emit TEXT_MESSAGE_START."
  def emit_text_message_start(agent_id, run_id, message_id \\ nil) do
    emit("TEXT_MESSAGE_START", %{
      agent_id: agent_id,
      run_id: run_id,
      message_id: message_id || generate_message_id()
    })
  end

  @doc "Emit TEXT_MESSAGE_CONTENT with a text delta."
  def emit_text_message_content(agent_id, run_id, content) do
    emit("TEXT_MESSAGE_CONTENT", %{
      agent_id: agent_id,
      run_id: run_id,
      content: content
    })
  end

  @doc "Emit TEXT_MESSAGE_END."
  def emit_text_message_end(agent_id, run_id) do
    emit("TEXT_MESSAGE_END", %{
      agent_id: agent_id,
      run_id: run_id
    })
  end

  @doc "Emit TOOL_CALL_START."
  def emit_tool_call_start(agent_id, run_id, tool_name, tool_call_id \\ nil) do
    emit("TOOL_CALL_START", %{
      agent_id: agent_id,
      run_id: run_id,
      tool_name: tool_name,
      tool_call_id: tool_call_id || generate_tool_call_id()
    })
  end

  @doc "Emit TOOL_CALL_ARGS with argument data."
  def emit_tool_call_args(agent_id, run_id, tool_call_id, args) do
    emit("TOOL_CALL_ARGS", %{
      agent_id: agent_id,
      run_id: run_id,
      tool_call_id: tool_call_id,
      args: args
    })
  end

  @doc "Emit TOOL_CALL_END."
  def emit_tool_call_end(agent_id, run_id, tool_call_id) do
    emit("TOOL_CALL_END", %{
      agent_id: agent_id,
      run_id: run_id,
      tool_call_id: tool_call_id
    })
  end

  @doc "Emit STATE_SNAPSHOT with full fleet state."
  def emit_state_snapshot(state_data) do
    emit("STATE_SNAPSHOT", %{
      agents: Map.get(state_data, :agents, []),
      sessions: Map.get(state_data, :sessions, []),
      notifications: Map.get(state_data, :notifications, [])
    })
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{sequence: 0, events: []}}
  end

  @impl true
  def handle_call({:emit, type, data}, _from, state) do
    seq = state.sequence + 1
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    event = %{
      type: type,
      data: data,
      timestamp: now,
      sequence: seq,
      run_id: Map.get(data, :run_id),
      thread_id: Map.get(data, :thread_id)
    }

    # Broadcast via PubSub
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:ag_ui_event, event})

    # Store event, capping at @max_events
    events = [event | state.events] |> Enum.take(@max_events)

    {:reply, event, %{state | sequence: seq, events: events}}
  end

  def handle_call({:get_events, nil, limit}, _from, state) do
    events = Enum.take(state.events, limit)
    {:reply, events, state}
  end

  def handle_call({:get_events, agent_id, limit}, _from, state) do
    events =
      state.events
      |> Enum.filter(fn e -> get_in(e, [:data, :agent_id]) == agent_id end)
      |> Enum.take(limit)

    {:reply, events, state}
  end

  def handle_call(:clear, _from, _state) do
    {:reply, :ok, %{sequence: 0, events: []}}
  end

  # --- Private Helpers ---

  defp generate_run_id do
    "run-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp generate_message_id do
    "msg-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp generate_tool_call_id do
    "tc-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
