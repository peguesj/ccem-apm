defmodule ApmV5.AuditLog do
  @moduledoc """
  Append-only audit log with hash chain integrity, ETS storage, ring buffer,
  and daily JSONL file rotation. Broadcasts events via PubSub.
  """

  use GenServer

  @pubsub ApmV5.PubSub
  @topic "apm:audit"
  @ets_table :apm_audit_log
  @ring_table :apm_audit_ring
  @ring_cap 10_000
  @log_dir Path.expand("~/.claude/ccem/apm/logs/audit")

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Clear all in-memory audit log entries.

  Test-only: raises in non-test environments to prevent accidental audit log
  destruction in dev/prod (audit-s2 v9.2.1 hardening).
  """
  @spec clear_all() :: :ok
  def clear_all do
    unless Mix.env() == :test do
      raise "AuditLog.clear_all/0 is test-only. Refusing to clear audit log in #{Mix.env()}."
    end

    GenServer.call(__MODULE__, :clear_all)
  end

  @doc "Async log - fire and forget, zero latency."
  @spec log(atom() | String.t(), String.t(), String.t(), map()) :: :ok
  def log(event_type, actor, resource, details \\ %{}) do
    GenServer.cast(__MODULE__, {:log, event_type, actor, resource, details, nil})
  end

  @doc "Sync log for critical events. Returns the event."
  @spec log_sync(atom() | String.t(), String.t(), String.t(), map(), String.t() | nil) :: map()
  def log_sync(event_type, actor, resource, details, correlation_id \\ nil) do
    GenServer.call(__MODULE__, {:log, event_type, actor, resource, details, correlation_id})
  end

  @doc "Query events with filters: event_type, actor, since, until, limit."
  @spec query(keyword()) :: [map()]
  def query(opts \\ []) do
    GenServer.call(__MODULE__, {:query, opts})
  end

  @doc "Get last N events from ring buffer."
  @spec tail(non_neg_integer()) :: [map()]
  def tail(n \\ 20) do
    GenServer.call(__MODULE__, {:tail, n})
  end

  @doc "Return counts by event_type."
  @spec stats() :: %{optional(atom() | String.t()) => non_neg_integer()}
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # --- Server ---

  @impl true
  def init(_opts) do
    # :protected — only the AuditLog GenServer can write; all processes can read.
    # Prevents tamper surface where any process could :ets.delete/2 audit entries
    # bypassing the GenServer (audit-s2 v9.2.1 hardening).
    :ets.new(@ets_table, [:ordered_set, :named_table, :protected, read_concurrency: true])
    :ets.new(@ring_table, [:set, :named_table, :protected, read_concurrency: true])
    log_dir = log_dir()
    {:ok, %{counter: 0, prev_hash: "genesis", log_dir: log_dir, today: Date.utc_today()}, {:continue, :init_log_dir}}
  end

  @impl true
  def handle_continue(:init_log_dir, state) do
    File.mkdir_p!(state.log_dir)
    {:noreply, state}
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
    include_decrypted = Keyword.get(opts, :include_decrypted, false)

    results =
      :ets.tab2list(@ets_table)
      |> Enum.map(fn {_k, event} -> event end)
      |> maybe_filter(:event_type, event_type)
      |> maybe_filter(:actor, actor)
      |> maybe_filter_since(since)
      |> maybe_filter_until(until_ts)
      |> Enum.take(limit)
      |> maybe_decrypt(include_decrypted)

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

  def handle_call(:clear_all, _from, state) do
    :ets.delete_all_objects(@ets_table)
    :ets.delete_all_objects(@ring_table)
    {:reply, :ok, %{state | counter: 0}}
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

    # comp-mg2: encrypt PII/sensitive fields BEFORE canonical event composition.
    # The self_hash chain therefore covers ciphertext, not plaintext —
    # tamper-evident without leaking raw PII into the hash chain.
    stored_details =
      if is_map(details) and ApmV5.Governance.Vault.sensitive?(details) do
        ApmV5.Governance.Vault.encrypt_details(details)
      else
        details
      end

    # Canonical event — hash input. EXCLUDES self_hash so the hash is not
    # self-referential. The chain links: hash(event_N) = prev_hash of event_N+1.
    canonical_event = %{
      id: id,
      timestamp: DateTime.to_iso8601(now),
      event_type: event_type,
      actor: actor,
      resource: resource,
      details: stored_details,
      correlation_id: correlation_id,
      prev_hash: state.prev_hash
    }

    canonical_json = Jason.encode!(canonical_event)
    self_hash = :crypto.hash(:sha256, canonical_json) |> Base.encode16(case: :lower)

    # Full event — what gets stored. INCLUDES self_hash so consumers can
    # forward-verify the chain from the JSONL files alone (audit-s1 v9.2.1).
    event = Map.put(canonical_event, :self_hash, self_hash)
    event_json = Jason.encode!(event)

    # ETS ordered set
    :ets.insert(@ets_table, {id, event})

    # Ring buffer - evict oldest if at cap
    ring_key = rem(id - 1, @ring_cap)
    :ets.insert(@ring_table, {ring_key, event})

    # Disk persistence — write the event WITH self_hash so chain verification
    # is possible from the JSONL file alone.
    append_to_file(event_json, today, state.log_dir)

    # PubSub broadcast
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:audit_event, event})

    {event, %{state | counter: id, prev_hash: self_hash, today: today}}
  end

  # ── Chain verification API (audit-s1 v9.2.1) ─────────────────────────────

  defmodule AuditIntegrityError do
    @moduledoc "Raised when the audit log hash chain fails verification."
    defexception [:message, :event_id, :expected_hash, :actual_hash]
  end

  @doc """
  Verifies the hash chain of a JSONL audit log file by re-computing each
  event's `self_hash` and checking that each event's `prev_hash` matches the
  previous event's `self_hash`.

  Returns `:ok` on success, raises `AuditIntegrityError` on first mismatch.
  """
  @spec verify_chain!(Path.t()) :: :ok | no_return()
  def verify_chain!(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(&Jason.decode!/1)
    |> Enum.reduce(nil, &verify_event!/2)

    :ok
  end

  @doc """
  Verifies the hash chain of in-memory ETS audit log entries.

  Returns `:ok` on success, raises `AuditIntegrityError` on first mismatch.
  """
  @spec verify_memory_chain() :: :ok | no_return()
  def verify_memory_chain do
    @ets_table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {id, _event} -> id end)
    |> Enum.map(fn {_id, event} -> event end)
    |> Enum.reduce(nil, &verify_event!/2)

    :ok
  end

  defp verify_event!(event, prev_self_hash) do
    expected_prev = get_either(event, :prev_hash)
    stored_self_hash = get_either(event, :self_hash)
    event_id = get_either(event, :id)

    # Check chain link
    if prev_self_hash != nil and expected_prev != prev_self_hash do
      raise AuditIntegrityError,
        message: "prev_hash mismatch at event #{event_id}",
        event_id: event_id,
        expected_hash: prev_self_hash,
        actual_hash: expected_prev
    end

    # Recompute self_hash by removing self_hash field (both possible key types)
    # and re-encoding via Jason. Jason's output is deterministic for a given
    # map, regardless of atom vs string keys at the top level.
    canonical =
      event
      |> Map.delete(:self_hash)
      |> Map.delete("self_hash")

    canonical_json = Jason.encode!(canonical)
    recomputed = :crypto.hash(:sha256, canonical_json) |> Base.encode16(case: :lower)

    if stored_self_hash != recomputed do
      raise AuditIntegrityError,
        message: "self_hash mismatch at event #{event_id} — event tampered",
        event_id: event_id,
        expected_hash: recomputed,
        actual_hash: stored_self_hash
    end

    stored_self_hash
  end

  defp get_either(map, atom_key) do
    Map.get(map, atom_key) || Map.get(map, to_string(atom_key))
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
    Application.get_env(:apm_v5, :audit_log_dir, @log_dir)
  end

  # comp-mg2: decrypt details when include_decrypted: true is requested.
  # Only decrypts events whose details map has encrypted __enc__ wrappers.
  defp maybe_decrypt(events, false), do: events

  defp maybe_decrypt(events, true) do
    Enum.map(events, fn event ->
      if is_map(event.details) do
        Map.put(event, :details, ApmV5.Governance.Vault.decrypt_details(event.details))
      else
        event
      end
    end)
  end
end
