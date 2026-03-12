defmodule ApmV4.ChatStore do
  @moduledoc """
  GenServer providing per-scope chat message persistence.

  Uses ETS for storage keyed by scope string (e.g. "project:myapp",
  "formation:fmt-001", "agent:agent-123"). Subscribes to AG-UI events
  for automatic TEXT_MESSAGE capture. Enforces 500-message FIFO per scope.
  """

  use GenServer

  @pubsub ApmV4.PubSub
  @ag_ui_topic "ag_ui:events"
  @chat_topic_prefix "apm:chat"
  @max_messages_per_scope 500
  @table :chat_messages

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List messages for a scope, newest first. Optional limit (default 50)."
  @spec list_messages(String.t(), non_neg_integer()) :: [map()]
  def list_messages(scope, limit \\ 50) do
    case :ets.lookup(@table, scope) do
      [{^scope, messages}] -> Enum.take(messages, limit)
      [] -> []
    end
  end

  @doc "Send a user message to a scope. Broadcasts via PubSub."
  @spec send_message(String.t(), String.t(), map()) :: {:ok, map()}
  def send_message(scope, content, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:send_message, scope, content, metadata})
  end

  @doc "Get a single message by ID."
  @spec get_message(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_message(message_id) do
    GenServer.call(__MODULE__, {:get_message, message_id})
  end

  @doc "Clear all messages for a scope."
  @spec clear_scope(String.t()) :: :ok
  def clear_scope(scope) do
    GenServer.cast(__MODULE__, {:clear_scope, scope})
  end

  @doc "Get the PubSub topic for a chat scope."
  @spec topic(String.t()) :: String.t()
  def topic(scope), do: "#{@chat_topic_prefix}:#{scope}"

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Phoenix.PubSub.subscribe(@pubsub, @ag_ui_topic)
    {:ok, %{table: table, buffers: %{}}}
  end

  @impl true
  def handle_call({:send_message, scope, content, metadata}, _from, state) do
    message = build_message(content, Map.merge(metadata, %{
      "scope" => scope,
      "role" => Map.get(metadata, "role", "user"),
      "source" => "chat_input"
    }))

    store_message(scope, message)
    broadcast_chat(scope, {:new_message, message})

    # Also emit as AG-UI TEXT_MESSAGE if EventStream is available
    try do
      ApmV4.EventStream.emit("TEXT_MESSAGE_START", %{
        agent_id: Map.get(metadata, "agent_id", "user"),
        message_id: message["id"],
        role: "user"
      })
      ApmV4.EventStream.emit("TEXT_MESSAGE_CONTENT", %{
        agent_id: Map.get(metadata, "agent_id", "user"),
        message_id: message["id"],
        content: content
      })
      ApmV4.EventStream.emit("TEXT_MESSAGE_END", %{
        agent_id: Map.get(metadata, "agent_id", "user"),
        message_id: message["id"]
      })
    rescue
      _ -> :ok
    end

    {:reply, {:ok, message}, state}
  end

  def handle_call({:get_message, message_id}, _from, state) do
    result =
      :ets.tab2list(@table)
      |> Enum.flat_map(fn {_scope, messages} -> messages end)
      |> Enum.find(fn msg -> msg["id"] == message_id end)

    case result do
      nil -> {:reply, {:error, :not_found}, state}
      msg -> {:reply, {:ok, msg}, state}
    end
  end

  @impl true
  def handle_cast({:clear_scope, scope}, state) do
    :ets.delete(@table, scope)
    broadcast_chat(scope, :cleared)
    {:noreply, state}
  end

  # Handle AG-UI TEXT_MESSAGE events from PubSub
  @impl true
  def handle_info({:ag_ui_event, %{type: "TEXT_MESSAGE_START"} = event}, state) do
    agent_id = event[:data][:agent_id] || event[:data]["agent_id"] || "unknown"
    message_id = event[:data][:message_id] || event[:data]["message_id"] || generate_id()
    role = event[:data][:role] || event[:data]["role"] || "assistant"

    buffer = %{
      "id" => message_id,
      "agent_id" => agent_id,
      "role" => role,
      "content" => "",
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:noreply, put_in(state, [:buffers, agent_id], buffer)}
  end

  def handle_info({:ag_ui_event, %{type: "TEXT_MESSAGE_CONTENT"} = event}, state) do
    agent_id = event[:data][:agent_id] || event[:data]["agent_id"] || "unknown"
    content = event[:data][:content] || event[:data]["content"] || ""

    state =
      case get_in(state, [:buffers, agent_id]) do
        nil -> state
        buffer ->
          updated = Map.update!(buffer, "content", &(&1 <> content))
          put_in(state, [:buffers, agent_id], updated)
      end

    {:noreply, state}
  end

  def handle_info({:ag_ui_event, %{type: "TEXT_MESSAGE_END"} = event}, state) do
    agent_id = event[:data][:agent_id] || event[:data]["agent_id"] || "unknown"

    state =
      case get_in(state, [:buffers, agent_id]) do
        nil -> state
        buffer ->
          scope = determine_scope(agent_id)
          message = build_message(buffer["content"], %{
            "scope" => scope,
            "role" => buffer["role"],
            "agent_id" => agent_id,
            "source" => "ag_ui",
            "id" => buffer["id"]
          })

          store_message(scope, message)
          broadcast_chat(scope, {:new_message, message})
          %{state | buffers: Map.delete(state.buffers, agent_id)}
      end

    {:noreply, state}
  end

  # Ignore other AG-UI events
  def handle_info({:ag_ui_event, _event}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp build_message(content, metadata) do
    id = Map.get(metadata, "id", generate_id())
    %{
      "id" => id,
      "content" => content,
      "role" => Map.get(metadata, "role", "user"),
      "scope" => Map.get(metadata, "scope", "global"),
      "agent_id" => Map.get(metadata, "agent_id"),
      "source" => Map.get(metadata, "source", "manual"),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp store_message(scope, message) do
    existing =
      case :ets.lookup(@table, scope) do
        [{^scope, messages}] -> messages
        [] -> []
      end

    updated = [message | existing] |> Enum.take(@max_messages_per_scope)
    :ets.insert(@table, {scope, updated})
  end

  defp broadcast_chat(scope, event) do
    Phoenix.PubSub.broadcast(@pubsub, topic(scope), {:chat_event, scope, event})
  end

  defp determine_scope(agent_id) do
    # Try to find the agent in the registry and derive scope
    case ApmV4.AgentRegistry.get_agent(agent_id) do
      {:ok, agent} ->
        cond do
          agent[:formation_id] -> "formation:#{agent[:formation_id]}"
          agent[:project] -> "project:#{agent[:project]}"
          true -> "agent:#{agent_id}"
        end
      _ -> "agent:#{agent_id}"
    end
  rescue
    _ -> "agent:#{agent_id}"
  end

  defp generate_id do
    "msg-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
