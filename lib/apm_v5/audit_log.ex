defmodule ApmV5.AuditLog do
  @moduledoc """
  Append-only audit log with hash chain integrity, ETS storage, ring buffer,
  and daily JSONL file rotation. Broadcasts events via PubSub.

  ## Schema version v2 (audit-s3 / CP-221)

  The stored event record now carries the full unified schema synthesised
  from OWASP, NIST 800-92, PCI DSS Req 10, and W3C Activity Streams 2.0:

  ```
  %{
    # Existing (v1)
    id:             integer,
    timestamp:      iso8601_string,
    event_type:     atom | string,
    actor:          string,
    resource:       string,
    details:        map,
    correlation_id: nil | string,
    prev_hash:      string,
    self_hash:      string,

    # New (v2 — audit-s3)
    event_id:       uuid_string,            # UUID per event for idempotency
    agent_id:       nil | string,           # typed agent identity (PCI Req 10)
    session_id:     nil | string,
    formation_id:   nil | string,
    wave:           nil | integer,
    project_name:   nil | string,
    severity:       nil | :info | :warning | :error | :critical,
    result:         nil | :success | :failure | :denied,
    tool_name:      nil | string,           # W3C `instrument`
    causation_id:   nil | string,           # eventstore causation pattern
  }
  ```

  All new fields default to `nil` so existing call sites remain valid.
  The canonical event (hash input) **includes** all new fields so the chain
  remains deterministic and forward-verifiable. Audit schema version bumped
  to `"v2"` and included in each record under `schema_version`.

  ## Backward-Compatibility

  Existing `log/4` and `log_sync/5` signatures are unchanged. The new
  `log_with_context/6` exposes the full context map. Existing JSONL files
  produced by v1 can still be verified by `verify_chain!/1` — the
  `verify_event!/2` function reads only the fields that were present.

  ## Chain Integrity

  `self_hash` = SHA-256(Jason.encode!(canonical_event))
  where `canonical_event` = the full record **minus** `:self_hash`.
  New fields ARE included in the canonical event so they participate in the
  chain. This is intentional: adding agent attribution after the fact would
  be detectable as a tamper.
  """

  use GenServer

  require Logger

  @pubsub ApmV5.PubSub
  @topic "apm:audit"
  @ets_table :apm_audit_log
  @ring_table :apm_audit_ring
  @ring_cap 10_000
  @log_dir Path.expand("~/.claude/ccem/apm/logs/audit")
  @schema_version "v2"

  # ── Client API ─────────────────────────────────────────────────────────────

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

  @doc """
  Async log - fire and forget, zero latency.

  Maintains v1 signature. Context defaults to `%{}` (all new fields nil).
  """
  @spec log(atom() | String.t(), String.t(), String.t(), map()) :: :ok
  def log(event_type, actor, resource, details \\ %{}) do
    GenServer.cast(__MODULE__, {:log, event_type, actor, resource, details, nil, %{}})
  end

  @doc """
  Sync log for critical events. Returns the event.

  Maintains v1 signature. Context defaults to `%{}` (all new fields nil).
  """
  @spec log_sync(atom() | String.t(), String.t(), String.t(), map(), String.t() | nil) :: map()
  def log_sync(event_type, actor, resource, details, correlation_id \\ nil) do
    GenServer.call(__MODULE__, {:log, event_type, actor, resource, details, correlation_id, %{}})
  end

  @doc """
  Async log with full agent attribution context.

  Context map may include any subset of:
  - `agent_id`     - typed agent identity string
  - `session_id`   - Claude Code session ID
  - `formation_id` - formation identifier
  - `wave`         - wave number (integer)
  - `project_name` - project root or name
  - `severity`     - `:info | :warning | :error | :critical` (default `:info`)
  - `result`       - `:success | :failure | :denied`
  - `tool_name`    - the tool that triggered the event
  - `causation_id` - UUID of the causing event
  """
  @spec log_with_context(
          atom() | String.t(),
          String.t(),
          String.t(),
          map(),
          String.t() | nil,
          map()
        ) :: :ok
  def log_with_context(event_type, actor, resource, details, correlation_id, context) do
    GenServer.cast(
      __MODULE__,
      {:log, event_type, actor, resource, details, correlation_id, context}
    )
  end

  @doc """
  Sync log with full agent attribution context. Returns the event.
  """
  @spec log_sync_with_context(
          atom() | String.t(),
          String.t(),
          String.t(),
          map(),
          String.t() | nil,
          map()
        ) :: map()
  def log_sync_with_context(event_type, actor, resource, details, correlation_id, context) do
    GenServer.call(
      __MODULE__,
      {:log, event_type, actor, resource, details, correlation_id, context}
    )
  end

  @doc """
  Query events with filters.

  ## v1 filters (unchanged)
  - `event_type:` - exact match
  - `actor:` - exact match
  - `since:` - ISO 8601 string lower-bound on timestamp
  - `until:` - ISO 8601 string upper-bound on timestamp
  - `limit:` - max results (default 100)

  ## v2 filters (audit-s3)
  - `agent_id:` - exact match
  - `session_id:` - exact match
  - `formation_id:` - exact match
  - `severity:` - atom exact match
  - `result:` - atom exact match

  ## v3 cursor pagination (audit-s8)
  - `after:` - integer cursor; return only events with `id > after`
  """
  @spec query(keyword()) :: [map()]
  def query(opts \\ []) do
    GenServer.call(__MODULE__, {:query, opts})
  end

  @doc """
  Paginated query returning a `{events, next_cursor}` tuple.

  `next_cursor` is the integer id of the last returned event, or `nil` when
  the result set is empty. Pass `next_cursor` back as `after:` to advance the
  page.

  Accepts all filters supported by `query/1` plus:
  - `after:` — integer id cursor (exclusive lower bound)
  - `limit:` — page size (default 50, max 500)

  ## Example

      iex> {page1, cursor} = ApmV5.AuditLog.query_page(limit: 10)
      iex> {page2, _cursor2} = ApmV5.AuditLog.query_page(after: cursor, limit: 10)
  """
  @spec query_page(keyword()) :: {[map()], integer() | nil}
  def query_page(opts \\ []) do
    GenServer.call(__MODULE__, {:query_page, opts})
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

  @doc """
  Online retention window in days. Files older than this are permanently deleted.

  Configurable via `config :apm_v5, :audit_log_retention_online_days, N`.
  Default: 90 days.
  """
  @spec online_days() :: pos_integer()
  def online_days, do: Application.get_env(:apm_v5, :audit_log_retention_online_days, 90)

  @doc """
  Archive retention window in days. Files older than this threshold are removed
  during the nightly purge sweep. Supersedes `online_days/0` — this is the
  outer boundary before permanent deletion.

  Configurable via `config :apm_v5, :audit_log_retention_archive_days, N`.
  Default: 365 days.
  """
  @spec archive_days() :: pos_integer()
  def archive_days, do: Application.get_env(:apm_v5, :audit_log_retention_archive_days, 365)

  # ── Server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # :protected — only the AuditLog GenServer can write; all processes can read.
    # Prevents tamper surface where any process could :ets.delete/2 audit entries
    # bypassing the GenServer (audit-s2 v9.2.1 hardening).
    :ets.new(@ets_table, [:ordered_set, :named_table, :protected, read_concurrency: true])
    :ets.new(@ring_table, [:set, :named_table, :protected, read_concurrency: true])
    log_dir = log_dir()
    {:ok, %{counter: 0, prev_hash: "genesis", log_dir: log_dir, today: Date.utc_today()},
     {:continue, :init_log_dir}}
  end

  @impl true
  def handle_continue(:init_log_dir, state) do
    File.mkdir_p!(state.log_dir)
    # Schedule the first daily purge run. Subsequent runs reschedule themselves.
    Process.send_after(self(), :daily_purge, ms_until_midnight())
    {:noreply, state}
  end

  @impl true
  def handle_cast({:log, event_type, actor, resource, details, correlation_id, context}, state) do
    {_event, state} = do_log(event_type, actor, resource, details, correlation_id, context, state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:log, event_type, actor, resource, details, correlation_id, context}, _from, state) do
    {event, state} = do_log(event_type, actor, resource, details, correlation_id, context, state)
    {:reply, event, state}
  end

  def handle_call({:query, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    event_type = Keyword.get(opts, :event_type)
    actor = Keyword.get(opts, :actor)
    since = Keyword.get(opts, :since)
    until_ts = Keyword.get(opts, :until)
    # v2 filters
    agent_id = Keyword.get(opts, :agent_id)
    session_id = Keyword.get(opts, :session_id)
    formation_id = Keyword.get(opts, :formation_id)
    severity = Keyword.get(opts, :severity)
    result = Keyword.get(opts, :result)
    # v3 cursor filter (audit-s8)
    after_cursor = Keyword.get(opts, :after)
    # v3 cloak decryption (comp-mg2 / CP-235)
    include_decrypted = Keyword.get(opts, :include_decrypted, false)

    results =
      fetch_after_cursor(@ets_table, after_cursor)
      |> maybe_filter(:event_type, event_type)
      |> maybe_filter(:actor, actor)
      |> maybe_filter(:agent_id, agent_id)
      |> maybe_filter(:session_id, session_id)
      |> maybe_filter(:formation_id, formation_id)
      |> maybe_filter(:severity, severity)
      |> maybe_filter(:result, result)
      |> maybe_filter_since(since)
      |> maybe_filter_until(until_ts)
      |> Enum.take(limit)
      |> maybe_decrypt(include_decrypted)

    {:reply, results, state}
  end

  def handle_call({:query_page, opts}, _from, state) do
    limit = opts |> Keyword.get(:limit, 50) |> min(500)
    after_cursor = Keyword.get(opts, :after)
    event_type = Keyword.get(opts, :event_type)
    actor = Keyword.get(opts, :actor)
    since = Keyword.get(opts, :since)
    until_ts = Keyword.get(opts, :until)
    agent_id = Keyword.get(opts, :agent_id)
    session_id = Keyword.get(opts, :session_id)
    formation_id = Keyword.get(opts, :formation_id)
    severity = Keyword.get(opts, :severity)
    result = Keyword.get(opts, :result)

    events =
      fetch_after_cursor(@ets_table, after_cursor)
      |> maybe_filter(:event_type, event_type)
      |> maybe_filter(:actor, actor)
      |> maybe_filter(:agent_id, agent_id)
      |> maybe_filter(:session_id, session_id)
      |> maybe_filter(:formation_id, formation_id)
      |> maybe_filter(:severity, severity)
      |> maybe_filter(:result, result)
      |> maybe_filter_since(since)
      |> maybe_filter_until(until_ts)
      |> Enum.take(limit)

    next_cursor =
      case events do
        [] -> nil
        _ -> List.last(events).id
      end

    {:reply, {events, next_cursor}, state}
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

  # ── Retention / Purge ──────────────────────────────────────────────────────

  @impl true
  def handle_info(:daily_purge, state) do
    today = Date.utc_today()
    run_daily_purge(state.log_dir, today)
    # Reschedule for the next midnight
    Process.send_after(self(), :daily_purge, ms_until_midnight())
    {:noreply, %{state | today: today}}
  end

  @doc """
  Execute a single daily purge sweep over `log_dir` relative to `today`.

  - Files with a parsed date older than `archive_days()` are permanently deleted.
  - The file for `yesterday` (Date.add(today, -1)) is chmod 0444 (read-only),
    since its write rotation is complete.
  - Today's file and files within the online window are left untouched.

  Public so that tests can invoke it directly without running the GenServer's
  `:daily_purge` message or manipulating timers.
  """
  @spec run_daily_purge(Path.t(), Date.t()) :: :ok
  def run_daily_purge(log_dir, today \\ Date.utc_today()) do
    yesterday = Date.add(today, -1)
    archive_cutoff = Date.add(today, -archive_days())

    case File.ls(log_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.match?(&1, ~r/^ccem_audit_\d{4}-\d{2}-\d{2}\.jsonl$/))
        |> Enum.each(fn filename ->
          path = Path.join(log_dir, filename)
          date_str = filename |> String.replace("ccem_audit_", "") |> String.replace(".jsonl", "")

          case Date.from_iso8601(date_str) do
            {:ok, file_date} ->
              cond do
                # Older than archive window → permanently delete
                Date.compare(file_date, archive_cutoff) == :lt ->
                  case File.rm(path) do
                    :ok ->
                      Logger.info("[AuditLog] Purged archived log: #{filename}")

                    {:error, reason} ->
                      Logger.warning("[AuditLog] Failed to purge #{filename}: #{inspect(reason)}")
                  end

                # Yesterday's file (now closed/rotated) → make read-only
                Date.compare(file_date, yesterday) == :eq ->
                  case File.chmod(path, 0o444) do
                    :ok ->
                      Logger.debug("[AuditLog] chmod 0444: #{filename}")

                    {:error, reason} ->
                      Logger.warning("[AuditLog] chmod failed for #{filename}: #{inspect(reason)}")
                  end

                true ->
                  :ok
              end

            {:error, _} ->
              Logger.warning("[AuditLog] Could not parse date from filename: #{filename}")
          end
        end)

      {:error, reason} ->
        Logger.warning("[AuditLog] daily_purge: cannot list log dir #{log_dir}: #{inspect(reason)}")
    end

    :ok
  end

  # ── Internal ───────────────────────────────────────────────────────────────

  # do_log/7 — new arity with context map (audit-s3).
  # The context map contributes agent_id, session_id, formation_id, wave,
  # project_name, severity, result, tool_name, causation_id.
  # All fields are included in the canonical event (hash input) so tampering
  # with attribution after the fact is detectable.
  defp do_log(event_type, actor, resource, details, correlation_id, context, state)
       when is_map(context) do
    id = state.counter + 1
    now = DateTime.utc_now()
    today = Date.utc_today()

    event_id = generate_event_id()

    # Extract v2 context fields with nil defaults.
    agent_id = Map.get(context, :agent_id) || Map.get(context, "agent_id")
    session_id = Map.get(context, :session_id) || Map.get(context, "session_id")
    formation_id = Map.get(context, :formation_id) || Map.get(context, "formation_id")
    wave = Map.get(context, :wave) || Map.get(context, "wave")
    project_name = Map.get(context, :project_name) || Map.get(context, "project_name")
    severity = Map.get(context, :severity) || Map.get(context, "severity") || :info
    result_field = Map.get(context, :result) || Map.get(context, "result")
    tool_name = Map.get(context, :tool_name) || Map.get(context, "tool_name")
    causation_id = Map.get(context, :causation_id) || Map.get(context, "causation_id")

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
    # self-referential. All new v2 fields are included so agent attribution
    # participates in the chain (tampering them after the fact is detectable).
    canonical_event = %{
      schema_version: @schema_version,
      id: id,
      event_id: event_id,
      timestamp: DateTime.to_iso8601(now),
      event_type: event_type,
      actor: actor,
      resource: resource,
      details: stored_details,
      correlation_id: correlation_id,
      causation_id: causation_id,
      # v2 attribution
      agent_id: agent_id,
      session_id: session_id,
      formation_id: formation_id,
      wave: wave,
      project_name: project_name,
      severity: severity,
      result: result_field,
      tool_name: tool_name,
      # chain
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

    # Ring buffer — evict oldest if at cap
    ring_key = rem(id - 1, @ring_cap)
    :ets.insert(@ring_table, {ring_key, event})

    # Disk persistence — write the event WITH self_hash so chain verification
    # is possible from the JSONL file alone.
    append_to_file(event_json, today, state.log_dir)

    # PubSub broadcast
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:audit_event, event})

    # Fire-and-forget sink dispatch — each configured sink runs in its own
    # Task so sink latency NEVER blocks the GenServer.
    dispatch_sinks(event)

    # Ed25519 artifact attestation (prov-w1-s3 / CP-277):
    # Produce a signed attestation for :tool_call events whose tool_name is
    # Write, Edit, or MultiEdit. Runs in a Task — never blocks the GenServer.
    ApmV5.Provenance.ArtifactAttestation.Signer.maybe_attest(
      event_type,
      resource,
      agent_id,
      tool_name,
      context
    )

    {event, %{state | counter: id, prev_hash: self_hash, today: today}}
  end

  # ── Sink dispatch (audit-s7) ─────────────────────────────────────────────────

  @doc """
  Dispatch `event` to every configured audit sink using `Task.start/1`.

  Sinks are resolved at call-time from `config :apm_v5, :audit_sinks`.  The
  default is `[]` (no sinks).  Each sink module MUST implement the
  `ApmV5.AuditLog.Sink` behaviour.

  ## Example config

      # config/config.exs
      config :apm_v5, :audit_sinks, []

      # config/prod.exs (opt-in for SIEM delivery)
      config :apm_v5, :audit_sinks, [ApmV5.AuditLog.Sinks.HttpSink]

  Each `Task.start/1` is fire-and-forget — a crash inside a sink does NOT
  propagate back to the caller or the `AuditLog` GenServer.
  """
  @spec dispatch_sinks(map()) :: :ok
  def dispatch_sinks(event) do
    sinks = Application.get_env(:apm_v5, :audit_sinks, [])

    Enum.each(sinks, fn sink_module ->
      Task.start(fn ->
        try do
          case sink_module.push_event(event) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "[AuditLog] Sink #{inspect(sink_module)} returned error: #{inspect(reason)}"
              )
          end
        rescue
          e ->
            Logger.warning(
              "[AuditLog] Sink #{inspect(sink_module)} raised: #{inspect(e)}"
            )
        end
      end)
    end)

    :ok
  end

  defp generate_event_id do
    # Generate a UUID v4 using :crypto without requiring Ecto or Bitwise.
    # Pattern-match bit fields per RFC 4122 §4.4.
    <<a::32, b::16, _::4, c::12, _::2, d::30, e::16, f::48>> =
      :crypto.strong_rand_bytes(16)

    # Set version 4 (0100) and variant bits (10xx) inline.
    :io_lib.format(
      "~8.16.0b-~4.16.0b-4~3.16.0b-~2.16.0b~4.16.0b-~12.16.0b",
      [a, b, c, 0x80 + rem(d, 0x40), e, f]
    )
    |> to_string()
  rescue
    _ ->
      # Fallback: hex-encoded 16 random bytes (not UUID format but unique)
      :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
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

  Compatible with both v1 (no agent attribution fields) and v2 JSONL files —
  the canonical event is reconstructed by removing `self_hash` only.
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

  # Returns events from @ets_table with id > cursor (or all events when cursor
  # is nil). The ETS table is an :ordered_set keyed by integer id — we use
  # :ets.select/2 with a match spec to filter server-side, avoiding a full
  # tab2list when a cursor is given.
  defp fetch_after_cursor(_table, nil) do
    :ets.tab2list(@ets_table)
    |> Enum.map(fn {_k, event} -> event end)
  end

  defp fetch_after_cursor(_table, cursor) when is_integer(cursor) do
    # Match spec: match all entries {Key, Value} where Key > cursor,
    # returning the Value (the event map).
    match_spec = [{{:"$1", :"$2"}, [{:>, :"$1", cursor}], [:"$2"]}]
    :ets.select(@ets_table, match_spec)
  end

  # Returns milliseconds from now until the next UTC midnight.
  # Used to schedule the daily purge at a consistent wall-clock time.
  @spec ms_until_midnight() :: non_neg_integer()
  defp ms_until_midnight do
    now = DateTime.utc_now()
    tomorrow = now |> DateTime.to_date() |> Date.add(1)

    midnight =
      DateTime.new!(tomorrow, ~T[00:00:00], "Etc/UTC")

    diff_sec = DateTime.diff(midnight, now, :second)
    # Clamp to at least 1 second to avoid tight loops on boundary conditions.
    max(diff_sec * 1_000, 1_000)
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
