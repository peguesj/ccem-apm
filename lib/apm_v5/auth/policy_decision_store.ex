defmodule ApmV5.Auth.PolicyDecisionStore do
  @moduledoc """
  Queryable ETS ring buffer for authorization decisions.

  Records every authorization decision produced by `AuthorizationGate`
  with full context for NIST AI RMF GOVERN evidence, compliance audit
  trails, and real-time policy analytics.

  Distinct from `ApprovalAuditLog` — that log records human approval/deny
  decisions on *pending* escalations. This store records the machine-made
  AUTHORIZATION decision for every tool call, including auto-allowed,
  auto-denied, rate-limited, and escalated requests.

  ## Design
  - ETS `:ordered_set`, `:protected`, `read_concurrency: true`
  - Ring buffer cap of 50,000 entries via counter-based eviction
  - Counter-keyed so `{counter, id}` ordering gives natural insertion order
  - PubSub broadcast on `"auth:decisions"` after each record
  - `query/1` supports agent_id, session_id, formation_id, outcome,
    since/until time windows, and limit

  ## NIST AI RMF
  Provides GOVERN-layer evidence per GAP 5 of `docs/drtw-governance/01-authorization.md`.

  Part of CP-227 / US-459 — v9.3.0 Governance Foundation sprint.
  """

  use GenServer
  require Logger

  @table :policy_decisions
  @max_entries 50_000
  @pubsub_topic "auth:decisions"

  # ── Types ───────────────────────────────────────────────────────────────────

  @type outcome :: :allow | :deny | :ask
  @type risk_level :: :none | :low | :medium | :high | :critical

  @type decision_record :: %{
          id: String.t(),
          counter: non_neg_integer(),
          policy_id: String.t() | nil,
          agent_id: String.t(),
          session_id: String.t(),
          formation_id: String.t() | nil,
          tool_name: String.t(),
          risk_level: risk_level(),
          outcome: outcome(),
          trust_level: String.t() | nil,
          latency_ms: non_neg_integer() | nil,
          timestamp: DateTime.t()
        }

  @type query_filter :: %{
          optional(:agent_id) => String.t(),
          optional(:session_id) => String.t(),
          optional(:formation_id) => String.t(),
          optional(:outcome) => outcome(),
          optional(:since) => DateTime.t(),
          optional(:until) => DateTime.t(),
          optional(:limit) => pos_integer()
        }

  # ── Client API ───────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Asynchronously record an authorization decision.

  The map must include at minimum: `agent_id`, `session_id`, `tool_name`,
  `outcome` (`:allow | :deny | :ask`). Optional fields: `policy_id`,
  `formation_id`, `risk_level`, `trust_level`, `latency_ms`.
  Timestamp is set automatically if omitted.

  Returns `:ok` immediately; PubSub broadcast happens in the GenServer.
  """
  @spec record_decision(map()) :: :ok
  def record_decision(attrs) when is_map(attrs) do
    GenServer.cast(__MODULE__, {:record, attrs})
  end

  @doc """
  Synchronously record an authorization decision.

  Same as `record_decision/1` but waits for the record to be stored and
  returns it. Useful in hot-path contexts that need the assigned `id`.
  """
  @spec record_sync(map()) :: {:ok, decision_record()}
  def record_sync(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:record_sync, attrs})
  end

  @doc """
  Query decisions with a filter map.

  Accepted keys (all optional):
  - `:agent_id` — substring match against `agent_id`
  - `:session_id` — exact match
  - `:formation_id` — exact match
  - `:outcome` — `:allow | :deny | :ask`
  - `:since` — `DateTime` lower bound (inclusive)
  - `:until` — `DateTime` upper bound (inclusive)
  - `:limit` — max results (default 200)

  Results are returned newest-first.
  """
  @spec query(query_filter()) :: [decision_record()]
  def query(filter \\ %{}) when is_map(filter) do
    case :ets.info(@table) do
      :undefined -> []
      _ -> do_query(filter)
    end
  end

  @doc """
  Return the most recent `limit` decisions (default 100).
  """
  @spec latest(pos_integer()) :: [decision_record()]
  def latest(limit \\ 100) when is_integer(limit) and limit > 0 do
    query(%{limit: limit})
  end

  @doc """
  Return all decisions for a given `session_id`, newest first (up to 500).
  """
  @spec by_session(String.t()) :: [decision_record()]
  def by_session(session_id) when is_binary(session_id) do
    query(%{session_id: session_id, limit: 500})
  end

  @doc """
  Return the current count of stored decisions.
  """
  @spec count() :: non_neg_integer()
  def count do
    case :ets.info(@table) do
      :undefined -> 0
      _ -> :ets.info(@table, :size)
    end
  end

  @doc """
  Return decision counts grouped by outcome.

  Example: `%{allow: 1200, deny: 45, ask: 12}`
  """
  @spec stats() :: %{allow: non_neg_integer(), deny: non_neg_integer(), ask: non_neg_integer()}
  def stats do
    case :ets.info(@table) do
      :undefined ->
        %{allow: 0, deny: 0, ask: 0}

      _ ->
        :ets.tab2list(@table)
        |> Enum.reduce(%{allow: 0, deny: 0, ask: 0}, fn {_key, record}, acc ->
          Map.update(acc, record.outcome, 1, &(&1 + 1))
        end)
    end
  end

  @doc """
  Clear all entries. Test-only.

  Raises in non-test environments to prevent accidental destruction of
  compliance evidence records.
  """
  @spec clear() :: :ok
  def clear do
    unless Mix.env() == :test do
      raise "PolicyDecisionStore.clear/0 is test-only. Refusing to clear in #{Mix.env()}."
    end

    GenServer.call(__MODULE__, :clear)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # :protected — only the GenServer can write; all processes can read directly.
    # :ordered_set — keys are {counter, id} tuples, enabling efficient range scans.
    :ets.new(@table, [:named_table, :ordered_set, :protected, {:read_concurrency, true}])
    {:ok, %{counter: 0}}
  end

  @impl true
  def handle_cast({:record, attrs}, state) do
    {record, new_state} = do_insert(attrs, state)
    broadcast(record)
    {:noreply, new_state}
  end

  @impl true
  def handle_call({:record_sync, attrs}, _from, state) do
    {record, new_state} = do_insert(attrs, state)
    broadcast(record)
    {:reply, {:ok, record}, new_state}
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{counter: 0}}
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp do_insert(attrs, %{counter: counter} = state) do
    id = "pd-#{counter}"

    record =
      attrs
      |> normalize_record()
      |> Map.put(:id, id)
      |> Map.put(:counter, counter)
      |> Map.put_new(:timestamp, DateTime.utc_now())

    # ETS key is {counter, id} so :ordered_set gives insertion-order traversal
    ets_key = {counter, id}
    :ets.insert(@table, {ets_key, record})

    # Ring buffer eviction: remove oldest entry when over cap
    if counter >= @max_entries do
      old_counter = counter - @max_entries
      old_key = {old_counter, "pd-#{old_counter}"}
      :ets.delete(@table, old_key)
    end

    Logger.debug(
      "[PolicyDecisionStore] #{record.agent_id}/#{record.tool_name} -> #{record.outcome}"
    )

    {record, %{state | counter: counter + 1}}
  end

  defp normalize_record(attrs) do
    %{
      policy_id: Map.get(attrs, :policy_id),
      agent_id: to_string(Map.get(attrs, :agent_id, "unknown")),
      session_id: to_string(Map.get(attrs, :session_id, "default")),
      formation_id: Map.get(attrs, :formation_id),
      tool_name: to_string(Map.get(attrs, :tool_name, "unknown")),
      risk_level: coerce_risk(Map.get(attrs, :risk_level, :none)),
      outcome: coerce_outcome(Map.get(attrs, :outcome, :allow)),
      trust_level: Map.get(attrs, :trust_level),
      latency_ms: Map.get(attrs, :latency_ms),
      timestamp: Map.get(attrs, :timestamp, DateTime.utc_now())
    }
  end

  defp coerce_outcome(o) when o in [:allow, :deny, :ask], do: o
  defp coerce_outcome("allow"), do: :allow
  defp coerce_outcome("deny"), do: :deny
  defp coerce_outcome("ask"), do: :ask
  defp coerce_outcome(_), do: :allow

  defp coerce_risk(r) when r in [:none, :low, :medium, :high, :critical], do: r
  defp coerce_risk("none"), do: :none
  defp coerce_risk("low"), do: :low
  defp coerce_risk("medium"), do: :medium
  defp coerce_risk("high"), do: :high
  defp coerce_risk("critical"), do: :critical
  defp coerce_risk(_), do: :none

  defp broadcast(record) do
    Phoenix.PubSub.broadcast(
      ApmV5.PubSub,
      @pubsub_topic,
      {:policy_decision, record}
    )
  end

  defp do_query(filter) do
    limit = Map.get(filter, :limit, 200)

    :ets.tab2list(@table)
    |> Enum.map(fn {_key, record} -> record end)
    |> apply_filter(:agent_id, Map.get(filter, :agent_id))
    |> apply_filter(:session_id, Map.get(filter, :session_id))
    |> apply_filter(:formation_id, Map.get(filter, :formation_id))
    |> apply_filter(:outcome, Map.get(filter, :outcome))
    |> apply_since(Map.get(filter, :since))
    |> apply_until(Map.get(filter, :until))
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    |> Enum.take(limit)
  end

  # agent_id — substring match
  defp apply_filter(records, :agent_id, nil), do: records

  defp apply_filter(records, :agent_id, val) do
    Enum.filter(records, &String.contains?(to_string(&1.agent_id), val))
  end

  # session_id — exact match
  defp apply_filter(records, :session_id, nil), do: records

  defp apply_filter(records, :session_id, val) do
    Enum.filter(records, &(&1.session_id == val))
  end

  # formation_id — exact match
  defp apply_filter(records, :formation_id, nil), do: records

  defp apply_filter(records, :formation_id, val) do
    Enum.filter(records, &(&1.formation_id == val))
  end

  # outcome — exact atom match
  defp apply_filter(records, :outcome, nil), do: records

  defp apply_filter(records, :outcome, val) do
    Enum.filter(records, &(&1.outcome == val))
  end

  defp apply_since(records, nil), do: records

  defp apply_since(records, since) do
    Enum.filter(records, &(DateTime.compare(&1.timestamp, since) != :lt))
  end

  defp apply_until(records, nil), do: records

  defp apply_until(records, until_dt) do
    Enum.filter(records, &(DateTime.compare(&1.timestamp, until_dt) != :gt))
  end
end
