defmodule ApmV5.AgUi.EventBus do
  @moduledoc """
  Centralized AG-UI event bus replacing ad-hoc PubSub broadcasts.

  All events are validated against AgUi.Core.Events.EventType before dispatch,
  with per-topic subscription support and backpressure via mailbox monitoring.

  ## Topics
  Events are published to hierarchical topics defined by ApmV5.AgUi.Topics.
  Subscribers can use wildcard patterns (e.g., "lifecycle:*") to receive
  all events in a category.

  ## US-001 Acceptance Criteria (DoD):
  - GenServer starts in supervision tree after EventStream
  - publish/2 validates event type via EventType.valid?/1
  - subscribe/1 accepts topic patterns and delivers matching events
  - unsubscribe/1 removes calling process from subscriptions
  - stats/0 returns %{published_count, subscribers_count, by_topic}
  - Events forwarded to EventStream.emit/2 for sequence numbering
  """

  use GenServer

  require Logger

  alias ApmV5.EventStream

  @table :ag_ui_event_bus_subs

  # -- Client API -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Publishes an event through the EventBus.

  Validates the event type against AgUi.Core.Events.EventType.valid?/1.
  Returns {:ok, event} on success or {:error, :invalid_event_type} for unknown types.

  Events are forwarded to EventStream.emit/2 for sequence numbering and persistence,
  then delivered to all matching topic subscribers.
  """
  @spec publish(String.t(), map()) :: {:ok, map()} | {:error, :invalid_event_type}
  def publish(type, data \\ %{}) do
    if AgUi.Core.Events.EventType.valid?(type) do
      event = EventStream.emit(type, data)
      GenServer.cast(__MODULE__, {:dispatch, type, event})
      {:ok, event}
    else
      {:error, :invalid_event_type}
    end
  end

  @doc """
  Subscribes the calling process to a topic pattern.

  Patterns support wildcards: "lifecycle:*" matches "lifecycle:run_started", etc.
  The subscribing process will receive {:event_bus, topic, event} messages.
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(pattern) do
    GenServer.call(__MODULE__, {:subscribe, pattern, self()})
  end

  @doc """
  Removes the calling process from all topic subscriptions.
  """
  @spec unsubscribe() :: :ok
  def unsubscribe do
    GenServer.call(__MODULE__, {:unsubscribe, self()})
  end

  @doc """
  Returns EventBus statistics.

  Returns %{published_count, subscribers_count, by_topic} map.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # -- GenServer Callbacks ----------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :bag, :protected, read_concurrency: true])
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       table: table,
       published_count: 0,
       by_topic: %{}
     }}
  end

  @impl true
  def handle_cast({:dispatch, type, event}, state) do
    topic = ApmV5.AgUi.Topics.topic_for(type)
    deliver_to_subscribers(topic, event)

    {:noreply,
     %{
       state
       | published_count: state.published_count + 1,
         by_topic: Map.update(state.by_topic, topic, 1, &(&1 + 1))
     }}
  end

  @impl true
  def handle_call({:subscribe, pattern, pid}, _from, state) do
    ref = Process.monitor(pid)
    :ets.insert(@table, {pattern, pid, ref})
    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    # Find and remove all subscriptions for this pid
    subs = :ets.match_object(@table, {:_, pid, :_})

    Enum.each(subs, fn {_pattern, _pid, ref} ->
      Process.demonitor(ref, [:flush])
      :ets.match_delete(@table, {:_, pid, ref})
    end)

    {:reply, :ok, state}
  end

  def handle_call(:stats, _from, state) do
    subscribers_count =
      :ets.tab2list(@table)
      |> Enum.map(fn {_pattern, pid, _ref} -> pid end)
      |> Enum.uniq()
      |> length()

    {:reply,
     %{
       published_count: state.published_count,
       subscribers_count: subscribers_count,
       by_topic: state.by_topic
     }, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    :ets.match_delete(@table, {:_, pid, ref})
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private ----------------------------------------------------------------

  defp deliver_to_subscribers(topic, event) do
    :ets.tab2list(@table)
    |> Enum.each(fn {pattern, pid, _ref} ->
      if ApmV5.AgUi.Topics.matches?(pattern, topic) do
        # Backpressure check: skip if mailbox > 1000
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, len} when len < 1000 ->
            send(pid, {:event_bus, topic, event})

          _ ->
            Logger.warning("EventBus: dropping event for #{inspect(pid)} (mailbox full)")
        end
      end
    end)
  end
end
