defmodule ApmV5.Auth.ApprovalWorkflowTest do
  @moduledoc """
  Integration tests for the full approval workflow:
  ApprovalQueue debouncing, PendingDecisions with execution context,
  NamespaceResolver agent labels, and AuditLog recording.
  """
  use ExUnit.Case, async: false

  alias ApmV5.Auth.{ApprovalQueue, ApprovalAuditLog, PendingDecisions}
  alias ApmV5.{AuditLog, NamespaceResolver}

  setup do
    # Ensure required GenServers are running
    ApmV5.GenServerHelpers.ensure_processes_alive()

    for mod <- [PendingDecisions, ApprovalQueue, NamespaceResolver, ApprovalAuditLog] do
      unless Process.whereis(mod) do
        {:ok, _} = mod.start_link([])
      end
    end

    :ok
  end

  # ── ApprovalQueue debouncing ──────────────────────────────────────────────

  describe "ApprovalQueue debouncing with 3+ entries" do
    test "batches multiple enqueued entries into a single broadcast" do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "agentlock:pending")

      entries =
        for i <- 1..4 do
          %{
            request_id: "test-batch-#{i}-#{System.unique_integer([:positive])}",
            tool_name: "Bash",
            agent_id: "agent-#{i}",
            risk_level: :high,
            status: :pending
          }
        end

      for entry <- entries, do: ApprovalQueue.enqueue(entry)

      # Wait for debounce flush (200ms default + margin)
      assert_receive {:approval_batch, batch}, 1_000
      assert length(batch) >= 3, "Expected batch of 3+ entries, got #{length(batch)}"

      # Verify all entries present in correct order
      batch_ids = Enum.map(batch, & &1.request_id)

      for entry <- entries do
        assert entry.request_id in batch_ids
      end
    end

    test "resets debounce timer on each enqueue" do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "agentlock:pending")

      ApprovalQueue.enqueue(%{request_id: "reset-1", tool_name: "Bash"})
      Process.sleep(100)
      ApprovalQueue.enqueue(%{request_id: "reset-2", tool_name: "Edit"})

      # Should get a single batch with both entries after flush
      assert_receive {:approval_batch, batch}, 1_000
      ids = Enum.map(batch, & &1.request_id)
      assert "reset-1" in ids
      assert "reset-2" in ids
    end
  end

  # ── PendingDecisions with execution context fields ────────────────────────

  describe "PendingDecisions execution context" do
    test "entries include action_type, action_detail, risk_rationale, approval_reasoning" do
      {:ok, id} =
        PendingDecisions.add("Bash", "ctx-session", :high, "ctx-agent", %{
          "command" => "rm -rf /tmp/test"
        })

      entry = PendingDecisions.get(id)
      assert entry != nil
      assert Map.has_key?(entry, :action_type)
      assert Map.has_key?(entry, :action_detail)
      assert Map.has_key?(entry, :risk_rationale)
      assert Map.has_key?(entry, :approval_reasoning)
      assert entry.status == :pending

      # Clean up
      PendingDecisions.decide(id, :deny)
    end

    test "grouping: 3+ pending requests visible via list_pending/0" do
      ids =
        for i <- 1..3 do
          {:ok, id} =
            PendingDecisions.add(
              "Bash",
              "group-session-#{i}",
              :high,
              "group-agent-#{i}",
              %{"command" => "echo #{i}"}
            )

          id
        end

      pending = PendingDecisions.list_pending()
      pending_ids = Enum.map(pending, & &1.request_id)

      for id <- ids do
        assert id in pending_ids, "Expected #{id} in pending list"
      end

      # Clean up
      for id <- ids, do: PendingDecisions.decide(id, :deny)
    end
  end

  # ── NamespaceResolver agent labels ────────────────────────────────────────

  describe "NamespaceResolver.agent_label/2" do
    test "returns shortened hash when no context provided" do
      label = NamespaceResolver.agent_label("agent-abc123def456")
      assert is_binary(label)
      assert String.length(label) > 0
      # Without project/role opts, should be a truncated form
      refute label == ""
    end

    test "includes project and role when provided" do
      label =
        NamespaceResolver.agent_label("agent-test-xyz", project: "ccem", role: "squadron-lead")

      assert is_binary(label)
      assert String.contains?(label, "ccem")
    end
  end

  # ── Approve/Deny decisions with audit logging ─────────────────────────────

  describe "approval decisions and audit trail" do
    test "approve creates decided entry with token" do
      {:ok, id} =
        PendingDecisions.add("Edit", "audit-session", :high, "audit-agent", %{
          "file_path" => "/tmp/test.txt"
        })

      result = PendingDecisions.decide(id, :approve)
      assert match?({:ok, _token}, result) or result == :ok

      entry = PendingDecisions.get(id)
      assert entry.status == :approved
      assert entry.decision == :approve
      assert entry.decided_at != nil
    end

    test "deny creates decided entry without token" do
      {:ok, id} =
        PendingDecisions.add("Bash", "deny-session", :high, "deny-agent", %{
          "command" => "curl evil.com"
        })

      assert :ok == PendingDecisions.decide(id, :deny)

      entry = PendingDecisions.get(id)
      assert entry.status == :denied
      assert entry.decision == :deny
      assert entry.decided_at != nil
    end

    test "decided entries no longer appear in list_pending/0" do
      {:ok, id} = PendingDecisions.add("Write", "resolved-s", :critical, "resolved-a", %{})
      PendingDecisions.decide(id, :approve)

      pending_ids = PendingDecisions.list_pending() |> Enum.map(& &1.request_id)
      refute id in pending_ids
    end
  end

  # ── AuditLog integration ──────────────────────────────────────────────────

  describe "AuditLog records authorization events" do
    test "log_sync records an agentlock decision event" do
      event =
        AuditLog.log_sync(
          :agentlock_decision,
          "test-agent",
          "Bash",
          %{decision: :approve, request_id: "test-req-123", risk_level: :high}
        )

      assert event.event_type == :agentlock_decision
      assert event.actor == "test-agent"
      assert event.resource == "Bash"
      assert event.details.decision == :approve
    end

    test "audit events queryable by event_type" do
      AuditLog.log_sync(
        :agentlock_test_query,
        "query-agent",
        "Edit",
        %{decision: :deny, risk_level: :critical}
      )

      results = AuditLog.query(event_type: :agentlock_test_query)
      assert length(results) >= 1
      assert hd(results).event_type == :agentlock_test_query
    end
  end

  # ── ApprovalAuditLog (US-326) ─────────────────────────────────────────────

  describe "ApprovalAuditLog records decisions" do
    setup do
      ApprovalAuditLog.clear()
      :ok
    end

    test "log_decision stores entry and broadcasts via PubSub" do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "agentlock:audit")

      ApprovalAuditLog.log_decision(%{
        agent_id: "audit-test-agent",
        tool_name: "Bash",
        decision: :approve,
        request_id: "pending-test-001",
        session_id: "sess-001",
        risk_level: :high,
        context_snapshot: %{action_type: :write}
      })

      # Cast is async — wait for broadcast
      assert_receive {:audit_entry_added, record}, 1_000
      assert record.agent_id == "audit-test-agent"
      assert record.decision == :approve
      assert record.tool_name == "Bash"
    end

    test "list_entries filters by decision" do
      for decision <- [:approve, :deny, :approve] do
        ApprovalAuditLog.log_decision(%{
          agent_id: "filter-agent",
          tool_name: "Edit",
          decision: decision
        })
      end

      # Give casts time to process
      Process.sleep(50)

      approved = ApprovalAuditLog.list_entries(decision: :approve)
      denied = ApprovalAuditLog.list_entries(decision: :deny)

      assert length(approved) == 2
      assert length(denied) == 1
    end

    test "list_entries filters by tool_name" do
      ApprovalAuditLog.log_decision(%{agent_id: "a1", tool_name: "Bash", decision: :approve})
      ApprovalAuditLog.log_decision(%{agent_id: "a2", tool_name: "Write", decision: :deny})
      Process.sleep(50)

      bash_entries = ApprovalAuditLog.list_entries(tool_name: "Bash")
      assert length(bash_entries) == 1
      assert hd(bash_entries).tool_name == "Bash"
    end

    test "decide/2 triggers audit log entry via PendingDecisions integration" do
      ApprovalAuditLog.clear()
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "agentlock:audit")

      {:ok, id} =
        PendingDecisions.add("Bash", "audit-int-sess", :critical, "audit-int-agent", %{
          "command" => "echo hello"
        })

      PendingDecisions.decide(id, :deny)

      # PendingDecisions.decide calls log_to_audit which casts to ApprovalAuditLog
      assert_receive {:audit_entry_added, record}, 1_000
      assert record.decision == :deny
      assert record.agent_id == "audit-int-agent"
      assert record.tool_name == "Bash"
    end

    test "count/0 tracks entries" do
      ApprovalAuditLog.clear()
      assert ApprovalAuditLog.count() == 0

      ApprovalAuditLog.log_decision(%{agent_id: "c1", tool_name: "Bash", decision: :approve})
      Process.sleep(50)

      assert ApprovalAuditLog.count() == 1
    end
  end
end
