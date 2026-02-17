defmodule ApmV4.AuditLog do
  @moduledoc """
  Append-only audit log with hash chain integrity, ETS storage, ring buffer,
  and daily JSONL file rotation. Broadcasts events via PubSub.
  """

  use GenServer

  @pubsub ApmV4.PubSub
  @topic "apm:audit"
  @ets_table :apm_audit_log
  @ring_table :apm_audit_ring
  @ring_cap 10_000
  @log_dir Path.expand("~/.claude/ccem/apm/logs/audit")

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Async log - fire and forget, zero latency."
  def log(event_type, actor, resource, details \\ %{}) do
    GenServer.cast(__MODULE__, {:log, event_type, actor, resource, details, nil})
  end

  @doc "Sync log for critical events. Returns the event."
  def log_sync(event_type, actor, resource, details, correlation_id \\ nil) do
    GenServer.call(__MODULE__, {:log, event_type, actor, resource, details, correlation_id})
  end

  @doc "Query events with filters: event_type, actor, since, until, limit."
  def query(opts \\ []) do
    GenServer.call(__MODULE__, {:query, opts})
  end

  @doc "Get last N events from ring buffer."
  def tail(n \\ 20) do
    GenServer.call(__MODULE__, {:tail, n})
  end

  @doc "Return counts by event_type."
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # --- Server ---

  @impl true
  def init(_opts) do
    :ets.new(@ets_table, [:ordered_set, :named_table, :public, read_concurrency: true])
    :ets.new(@ring_table, [:set, :named_table, :public, read_concurrency: true])

    log_dir = log_dir()
    File.mkdir_p!(log_dir)

    {:ok, %{counter: 0, prev_hash: "genesis", log_dir: log_dir, today: Date.utc_today()}}
  end

  @impl true
  def handle_cast({:log, event_type, actor, resource, details, correlation_id}, state) do
    {_event, state} = do_log(event_type, actor, resource, details, correlation_id, state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:log, event_type, actor, resource, details, correlation_id}, _from, state) do
    {event, state} = do_log(event_type, actor, resource, details, correlation_id, state)
    {:reply, event, state}
  end

  def handle_call({:query, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    event_type = Keyword.get(opts, :event_type)
    actor = Keyword.get(opts, :actor)
    since = Keyword.get(opts, :since)
    until_ts = Keyword.get(opts, :until)

    results =
      :ets.tab2list(@ets_table)
      |> Enum.map(fn {_k, event} -> event end)
      |> maybe_filter(:event_type, event_type)
      |> maybe_filter(:actor, actor)
      |> maybe_filter_since(since)
      |> maybe_filter_until(until_ts)
      |> Enum.take(limit)

    {:reply, results, state}
  end

  def handle_call({:tail, n}, _from, state) do
    events =
      :ets.tab2list(@ring_table)
      |> Enum.map(fn {_k, event} -> event end)
      |> Enum.sort_by(& &1.id, :desc)
      |> Enum.take(n)

    {:reply, events, state}
  end

  def handle_call(:stats, _from, state) do
    counts =
      :ets.tab2list(@ets_table)
      |> Enum.map(fn {_k, event} -> event.event_type end)
      |> Enum.frequencies()

    {:reply, counts, state}
  end

  # --- Internal ---

  defp do_log(event_type, actor, resource, details, correlation_id, state) do
    id = state.counter + 1
    now = DateTime.utc_now()
    today = Date.utc_today()

    event = %{
      id: id,
      timestamp: DateTime.to_iso8601(now),
      event_type: event_type,
      actor: actor,
      resource: resource,
      details: details,
      correlation_id: correlation_id,
      prev_hash: state.prev_hash
    }

    json = Jason.encode!(event)
    hash = :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)

    # ETS ordered set
    :ets.insert(@ets_table, {id, event})

    # Ring buffer - evict oldest if at cap
    ring_key = rem(id - 1, @ring_cap)
    :ets.insert(@ring_table, {ring_key, event})

    # Disk persistence
    append_to_file(json, today, state.log_dir)

    # PubSub broadcast
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:audit_event, event})

    {event, %{state | counter: id, prev_hash: hash, today: today}}
  end

  defp append_to_file(json, date, log_dir) do
    filename = "ccem_audit_#{Date.to_iso8601(date)}.jsonl"
    path = Path.join(log_dir, filename)
    File.write!(path, json <> "\n", [:append])
  end

  defp maybe_filter(events, _field, nil), do: events
  defp maybe_filter(events, field, value) do
    Enum.filter(events, &(Map.get(&1, field) == value))
  end

  defp maybe_filter_since(events, nil), do: events
  defp maybe_filter_since(events, since) do
    Enum.filter(events, &(&1.timestamp >= since))
  end

  defp maybe_filter_until(events, nil), do: events
  defp maybe_filter_until(events, until_ts) do
    Enum.filter(events, &(&1.timestamp <= until_ts))
  end

  defp log_dir do
    Application.get_env(:apm_v4, :audit_log_dir, @log_dir)
  end
end
