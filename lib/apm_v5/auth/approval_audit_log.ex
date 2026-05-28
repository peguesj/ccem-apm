defmodule ApmV5.Auth.ApprovalAuditLog do
  @moduledoc """
  Stores authorization decisions with full context for audit trail.

  ETS-backed GenServer that records every approve/deny decision from
  PendingDecisions, including agent context, tool name, timestamps,
  and a snapshot of the request at decision time.

  Part of US-326 — approval history log with audit trail.
  """

  use GenServer
  require Logger

  @table :approval_audit_log
  @max_entries 10_000

  # ── Client API ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record an authorization decision.

  Entry must include: agent_id, tool_name, decision (:approve | :deny),
  and optionally context_snapshot, request_id, session_id, risk_level.
  Timestamp is added automatically if not provided.
  """
  @spec log_decision(map()) :: :ok
  def log_decision(entry) when is_map(entry) do
    GenServer.cast(__MODULE__, {:log, entry})
  end

  @doc """
  List audit log entries with optional filters.

  Options:
  - `agent_id:` — filter by agent ID (substring match)
  - `tool_name:` — filter by tool name (exact match)
  - `decision:` — filter by decision (:approve | :deny)
  - `since:` — only entries after this DateTime
  - `limit:` — max entries to return (default 200)
  """
  @spec list_entries(keyword()) :: [map()]
  def list_entries(opts \\ []) do
    case :ets.info(@table) do
      :undefined ->
        []

      _ ->
        agent_id = Keyword.get(opts, :agent_id)
        tool_name = Keyword.get(opts, :tool_name)
        decision = Keyword.get(opts, :decision)
        since = Keyword.get(opts, :since)
        limit = Keyword.get(opts, :limit, 200)

        :ets.tab2list(@table)
        |> Enum.map(fn {_id, entry} -> entry end)
        |> maybe_filter(:agent_id, agent_id)
        |> maybe_filter(:tool_name, tool_name)
        |> maybe_filter(:decision, decision)
        |> maybe_filter_since(since)
        |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
        |> Enum.take(limit)
    end
  end

  @doc """
  Clear all entries. Test-only.

  Raises in non-test environments to prevent accidental approval-audit
  destruction in dev/prod (audit-s2 v9.2.1 hardening).
  """
  @spec clear() :: :ok
  def clear do
    unless Mix.env() == :test do
      raise "ApprovalAuditLog.clear/0 is test-only. Refusing to clear in #{Mix.env()}."
    end

    GenServer.call(__MODULE__, :clear)
  end

  @doc "Count of entries in the log."
  @spec count() :: non_neg_integer()
  def count do
    case :ets.info(@table) do
      :undefined -> 0
      _ -> :ets.info(@table, :size)
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # :protected — only the GenServer can write; all processes can read.
    # Prevents tamper surface where any process could mutate approval audit
    # entries bypassing the GenServer (audit-s2 v9.2.1 hardening).
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{counter: 0}}
  end

  @impl true
  def handle_cast({:log, entry}, %{counter: counter} = state) do
    id = "audit-#{counter}"

    record =
      entry
      |> Map.put_new(:id, id)
      |> Map.put_new(:timestamp, DateTime.utc_now())
      |> Map.put_new(:request_id, nil)
      |> Map.put_new(:session_id, nil)
      |> Map.put_new(:risk_level, nil)
      |> Map.put_new(:context_snapshot, %{})

    :ets.insert(@table, {id, record})

    # Evict oldest if over capacity
    if counter >= @max_entries do
      evict_id = "audit-#{counter - @max_entries}"
      :ets.delete(@table, evict_id)
    end

    Phoenix.PubSub.broadcast(
      ApmV5.PubSub,
      "agentlock:audit",
      {:audit_entry_added, record}
    )

    # audit-s3: mirror to AuditLog with typed attribution so approval decisions
    # participate in the hash chain (CP-221 / US-453).
    mirror_to_audit_log(record)

    Logger.debug("[ApprovalAuditLog] Recorded: #{entry[:agent_id]} / #{entry[:tool_name]} -> #{entry[:decision]}")

    {:noreply, %{state | counter: counter + 1}}
  end

  # Mirror an approval decision record to the main AuditLog for chain inclusion.
  # Uses log_with_context so agent_id + session_id participate in the hash.
  defp mirror_to_audit_log(record) do
    try do
      decision = Map.get(record, :decision)
      result_atom = case decision do
        :approve -> :success
        :deny    -> :denied
        _        -> nil
      end

      context = %{
        agent_id: Map.get(record, :agent_id),
        session_id: Map.get(record, :session_id),
        tool_name: Map.get(record, :tool_name),
        severity: :info,
        result: result_atom
      }

      ApmV5.AuditLog.log_with_context(
        :approval_decision,
        Map.get(record, :agent_id) || "approval_system",
        Map.get(record, :tool_name) || "unknown",
        Map.drop(record, [:id]),
        Map.get(record, :request_id),
        context
      )
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{counter: 0}}
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp maybe_filter(entries, :agent_id, nil), do: entries
  defp maybe_filter(entries, :agent_id, agent_id) do
    Enum.filter(entries, &String.contains?(to_string(&1.agent_id), agent_id))
  end

  defp maybe_filter(entries, :tool_name, nil), do: entries
  defp maybe_filter(entries, :tool_name, tool_name) do
    Enum.filter(entries, &(&1.tool_name == tool_name))
  end

  defp maybe_filter(entries, :decision, nil), do: entries
  defp maybe_filter(entries, :decision, decision) do
    Enum.filter(entries, &(&1.decision == decision))
  end

  defp maybe_filter_since(entries, nil), do: entries
  defp maybe_filter_since(entries, since) do
    Enum.filter(entries, &(DateTime.compare(&1.timestamp, since) != :lt))
  end
end
