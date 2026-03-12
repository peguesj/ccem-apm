defmodule ApmV5.AgUi.A2A.Router do
  @moduledoc """
  Routes A2A messages between agents via EventBus.

  ## US-031 Acceptance Criteria (DoD):
  - GenServer with ETS table :ag_ui_a2a_queues
  - send/1 resolves addressing, delivers via EventBus 'a2a:{agent_id}'
  - Per-agent queue stores last 100 messages
  - get_messages/1, ack_message/2
  - Delivery stats tracked
  - TTL expiry check
  - mix compile --warnings-as-errors passes
  """

  use GenServer

  require Logger

  alias ApmV5.AgUi.A2A.{Envelope, Addressing}
  alias ApmV5.AgUi.EventBus

  @table :ag_ui_a2a_queues
  @max_queue_size 100

  # -- Client API -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Sends an A2A message."
  @spec send(Envelope.t() | map()) :: {:ok, String.t()} | {:error, term()}
  def send(%Envelope{} = env) do
    if Envelope.expired?(env) do
      {:error, :expired}
    else
      GenServer.call(__MODULE__, {:send, env})
    end
  end

  def send(attrs) when is_map(attrs) do
    case Envelope.new(attrs) do
      {:ok, env} -> __MODULE__.send(env)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Gets queued messages for an agent."
  @spec get_messages(String.t()) :: [map()]
  def get_messages(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, messages}] -> messages
      [] -> []
    end
  end

  @doc "Acknowledges a message, removing it from the queue."
  @spec ack_message(String.t(), String.t()) :: :ok
  def ack_message(agent_id, message_id) do
    GenServer.cast(__MODULE__, {:ack, agent_id, message_id})
  end

  @doc "Returns routing statistics."
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc "Returns message history for an agent (sent + received, last 50)."
  @spec history(String.t()) :: [map()]
  def history(agent_id) do
    GenServer.call(__MODULE__, {:history, agent_id})
  end

  # -- GenServer Callbacks ----------------------------------------------------

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    {:ok,
     %{
       sent_count: 0,
       delivered_count: 0,
       expired_count: 0,
       history: []
     }}
  end

  @impl true
  def handle_call({:send, env}, _from, state) do
    targets = Addressing.resolve(env.to)
    msg_map = Envelope.to_map(env)

    delivered =
      Enum.count(targets, fn agent_id ->
        enqueue(agent_id, msg_map)

        EventBus.publish("CUSTOM", %{
          name: "a2a_message",
          agent_id: agent_id,
          value: msg_map
        })

        true
      end)

    history_entry = Map.put(msg_map, :delivered_to, targets)
    history = Enum.take([history_entry | state.history], 200)

    {:reply, {:ok, env.id},
     %{
       state
       | sent_count: state.sent_count + 1,
         delivered_count: state.delivered_count + delivered,
         history: history
     }}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       sent_count: state.sent_count,
       delivered_count: state.delivered_count,
       expired_count: state.expired_count,
       queue_depths:
         :ets.tab2list(@table)
         |> Enum.into(%{}, fn {id, msgs} -> {id, length(msgs)} end)
     }, state}
  end

  def handle_call({:history, agent_id}, _from, state) do
    relevant =
      state.history
      |> Enum.filter(fn msg ->
        msg[:from_agent_id] == agent_id or agent_id in (msg[:delivered_to] || [])
      end)
      |> Enum.take(50)

    {:reply, relevant, state}
  end

  @impl true
  def handle_cast({:ack, agent_id, message_id}, state) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, messages}] ->
        updated = Enum.reject(messages, fn msg -> msg[:id] == message_id end)
        :ets.insert(@table, {agent_id, updated})

      [] ->
        :ok
    end

    {:noreply, state}
  end

  # -- Private ----------------------------------------------------------------

  defp enqueue(agent_id, msg_map) do
    messages =
      case :ets.lookup(@table, agent_id) do
        [{^agent_id, existing}] -> existing
        [] -> []
      end

    updated = Enum.take([msg_map | messages], @max_queue_size)
    :ets.insert(@table, {agent_id, updated})
  end
end
