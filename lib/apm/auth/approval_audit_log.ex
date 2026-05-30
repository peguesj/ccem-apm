defmodule Apm.Auth.ApprovalAuditLog do
  @moduledoc """
  Thin shim over `Apm.AuditLog` for approval decision records.

  audit-s4 (CP-222 / v9.3.0): merged into the unified AuditLog hash chain.
  All writes delegate to `AuditLog.log_sync_with_context/6` with
  `event_type: :approval_decision` so approval events participate in the
  single tamper-evident chain and the dual-GenServer schema divergence is closed.

  ## Public API — unchanged from v1
  - `log_decision/1` — record an approve/deny entry
  - `list_entries/1` — query entries (delegates to AuditLog.query/1)
  - `tail/1` — last N entries (delegates to AuditLog.tail/1, filtered)
  - `count/0` — total :approval_decision events in AuditLog
  - `clear/0` — test-only; clears the unified AuditLog

  ## Backward-Compatibility
  All existing callers (`PendingDecisions`, `AuthController`,
  `ApprovalHistoryLive`, `ApprovalsLive`) continue to work unchanged.
  The separate `:approval_audit_log` ETS table no longer exists; the
  `ApprovalAuditLog` GenServer is no longer started in the supervision tree
  (removed from `AuthSupervisor`).  The module itself requires no process to
  be alive — all functions are direct calls to AuditLog.
  """

  require Logger

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc """
  Record an authorization decision.

  Entry should include: agent_id, tool_name, decision (:approve | :deny),
  and optionally context_snapshot, request_id, session_id, risk_level.
  Delegates synchronously to AuditLog so the record lands in the hash chain
  before this function returns.
  """
  @spec log_decision(map()) :: :ok
  def log_decision(entry) when is_map(entry) do
    decision = Map.get(entry, :decision)

    result_atom =
      case decision do
        :approve -> :success
        :deny -> :denied
        _ -> nil
      end

    context = %{
      agent_id: Map.get(entry, :agent_id),
      session_id: Map.get(entry, :session_id),
      tool_name: Map.get(entry, :tool_name),
      severity: :info,
      result: result_atom
    }

    # Sync write so the caller gets chain-ordering guarantees.
    Apm.AuditLog.log_sync_with_context(
      :approval_decision,
      Map.get(entry, :agent_id) || "approval_system",
      Map.get(entry, :tool_name) || "unknown",
      entry,
      Map.get(entry, :request_id),
      context
    )

    # Broadcast on the legacy topic so existing LiveView subscribers continue
    # to receive live updates (ApprovalsLive subscribes to "agentlock:audit").
    Phoenix.PubSub.broadcast(
      Apm.PubSub,
      "agentlock:audit",
      {:audit_entry_added, entry}
    )

    Logger.debug(
      "[ApprovalAuditLog] Recorded: #{entry[:agent_id]} / #{entry[:tool_name]} -> #{entry[:decision]}"
    )

    :ok
  end

  @doc """
  List approval audit entries with optional filters.

  Delegates to `AuditLog.query/1` with `event_type: :approval_decision`
  pre-applied.  All v1 filter options (agent_id, tool_name, decision, since,
  limit) are supported via the unified query layer.

  Options:
  - `agent_id:` — filter by agent ID (exact match via AuditLog.query)
  - `tool_name:` — filter by tool name (post-filter on details field)
  - `decision:` — filter by decision (:approve | :deny) (post-filter)
  - `since:` — only entries after this DateTime (ISO 8601 string)
  - `limit:` — max entries (default 200)
  """
  @spec list_entries(keyword()) :: [map()]
  def list_entries(opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)
    agent_id = Keyword.get(opts, :agent_id)
    tool_name = Keyword.get(opts, :tool_name)
    decision = Keyword.get(opts, :decision)
    since = Keyword.get(opts, :since)

    query_opts =
      [event_type: :approval_decision, limit: limit]
      |> maybe_append(:agent_id, agent_id)
      |> maybe_append(:since, since && to_string(since))

    Apm.AuditLog.query(query_opts)
    |> post_filter(:tool_name, tool_name)
    |> post_filter(:decision, decision)
    |> Enum.map(&normalize_entry/1)
  end

  @doc """
  Last N approval audit entries, newest first.

  Because AuditLog.tail/1 returns the last N events across all event types,
  we query by :approval_decision specifically.
  """
  @spec tail(non_neg_integer()) :: [map()]
  def tail(n \\ 20) do
    list_entries(limit: n)
  end

  @doc "Count of :approval_decision entries in the unified AuditLog."
  @spec count() :: non_neg_integer()
  def count do
    Apm.AuditLog.query(event_type: :approval_decision, limit: 100_000)
    |> length()
  end

  @doc """
  Clear all audit log entries.

  Test-only: raises in non-test environments. Clears the unified AuditLog
  (same guard as `AuditLog.clear_all/0`).
  """
  @spec clear() :: :ok
  def clear do
    unless Mix.env() == :test do
      raise "ApprovalAuditLog.clear/0 is test-only. Refusing to clear in #{Mix.env()}."
    end

    Apm.AuditLog.clear_all()
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp maybe_append(opts, _key, nil), do: opts
  defp maybe_append(opts, key, value), do: Keyword.put(opts, key, value)

  # Post-filter on the details map inside the AuditLog entry.
  # AuditLog stores the original entry map as `details`, so approval-specific
  # fields (tool_name, decision) live under event.details.
  defp post_filter(entries, _field, nil), do: entries

  defp post_filter(entries, :tool_name, tool_name) do
    Enum.filter(entries, fn e ->
      Map.get(e, :resource) == tool_name ||
        Map.get(e.details || %{}, :tool_name) == tool_name
    end)
  end

  defp post_filter(entries, :decision, decision) do
    Enum.filter(entries, fn e ->
      Map.get(e.details || %{}, :decision) == decision
    end)
  end

  # Normalize an AuditLog event record back into the shape that callers of
  # list_entries/1 expected from the old ApprovalAuditLog ETS records:
  # a flat map with :agent_id, :tool_name, :decision, :timestamp, etc.
  defp normalize_entry(event) do
    details = Map.get(event, :details) || %{}

    %{
      id: Map.get(event, :event_id) || Map.get(event, :id),
      agent_id: Map.get(event, :agent_id) || Map.get(details, :agent_id),
      session_id: Map.get(event, :session_id) || Map.get(details, :session_id),
      tool_name: Map.get(event, :tool_name) || Map.get(details, :tool_name),
      decision: Map.get(details, :decision),
      risk_level: Map.get(details, :risk_level),
      request_id: Map.get(event, :correlation_id) || Map.get(details, :request_id),
      context_snapshot: Map.get(details, :context_snapshot) || %{},
      timestamp: Map.get(event, :timestamp),
      # Expose chain fields for transparency
      self_hash: Map.get(event, :self_hash),
      causation_id: Map.get(event, :causation_id)
    }
  end
end
