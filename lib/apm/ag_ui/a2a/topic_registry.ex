defmodule Apm.AgUi.A2A.TopicRegistry do
  @moduledoc """
  Topic subscription registry for A2A `{:topic, t}` addressing.

  Fixes the silent broadcast amplification bug where `Addressing.resolve({:topic, t})`
  previously returned ALL registered agents instead of only topic subscribers.

  Backed by ETS (`:a2a_topic_subscriptions`, `:bag` type) keyed on topic string,
  with `agent_id` values. Reads bypass the GenServer for low-latency address
  resolution; writes go through the GenServer for consistency.

  ## Topic naming convention

  Topics are free-form strings, but recommended namespacing:
    - `coalesce:skill-updates` — coalesce broadcast updates
    - `formation:<formation_id>:events` — formation-scoped events
    - `approvals:high-risk` — approval gate notifications

  ## Lifecycle

  Subscriptions persist for the lifetime of the GenServer. On agent termination,
  call `unsubscribe_all/1` to clean up — typically wired into `AgentRegistry`
  agent removal.

  Story `coord-a2` from v9.2.1 hotfix sprint. See DRTW report
  `docs/drtw-governance/09-multi-agent-coordination.md`.
  """
  use GenServer

  @table :a2a_topic_subscriptions
  @pubsub_topic "a2a:topic_registry"

  # ── Client API ──────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribe an agent to a topic. Idempotent — subscribing twice is a no-op.
  """
  @spec subscribe(String.t(), String.t()) :: :ok
  def subscribe(agent_id, topic)
      when is_binary(agent_id) and is_binary(topic) do
    GenServer.call(__MODULE__, {:subscribe, agent_id, topic})
  end

  @doc "Unsubscribe an agent from a single topic."
  @spec unsubscribe(String.t(), String.t()) :: :ok
  def unsubscribe(agent_id, topic)
      when is_binary(agent_id) and is_binary(topic) do
    GenServer.call(__MODULE__, {:unsubscribe, agent_id, topic})
  end

  @doc "Unsubscribe an agent from ALL topics. Used on agent termination."
  @spec unsubscribe_all(String.t()) :: :ok
  def unsubscribe_all(agent_id) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:unsubscribe_all, agent_id})
  end

  @doc """
  Returns the agent IDs subscribed to `topic`. Direct ETS read — bypasses
  GenServer for low-latency address resolution.
  """
  @spec get_subscribers(String.t()) :: [String.t()]
  def get_subscribers(topic) when is_binary(topic) do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _tid ->
        @table
        |> :ets.lookup(topic)
        |> Enum.map(fn {_topic, agent_id} -> agent_id end)
    end
  end

  @doc "Returns the topics an agent is subscribed to."
  @spec get_topics(String.t()) :: [String.t()]
  def get_topics(agent_id) when is_binary(agent_id) do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _tid ->
        @table
        |> :ets.match({:"$1", agent_id})
        |> List.flatten()
    end
  end

  @doc "Returns all topics with their subscriber counts. Diagnostic."
  @spec list_topics() :: [%{topic: String.t(), subscriber_count: non_neg_integer()}]
  def list_topics do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _tid ->
        @table
        |> :ets.tab2list()
        |> Enum.group_by(fn {topic, _agent_id} -> topic end)
        |> Enum.map(fn {topic, entries} ->
          %{topic: topic, subscriber_count: length(entries)}
        end)
        |> Enum.sort_by(& &1.topic)
    end
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :bag,
      :named_table,
      :protected,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  @impl true
  def handle_call({:subscribe, agent_id, topic}, _from, state) do
    # ETS bag deduplicates exact-match tuples — idempotent by design
    :ets.insert(@table, {topic, agent_id})
    broadcast({:subscribed, agent_id, topic})
    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe, agent_id, topic}, _from, state) do
    :ets.delete_object(@table, {topic, agent_id})
    broadcast({:unsubscribed, agent_id, topic})
    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe_all, agent_id}, _from, state) do
    @table
    |> :ets.match_object({:"$1", agent_id})
    |> Enum.each(&:ets.delete_object(@table, &1))

    broadcast({:unsubscribed_all, agent_id})
    {:reply, :ok, state}
  end

  # ── PubSub helper ───────────────────────────────────────────────────────

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(Apm.PubSub, @pubsub_topic, event)
  rescue
    _ -> :ok
  end
end
