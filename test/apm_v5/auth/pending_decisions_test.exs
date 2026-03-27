defmodule ApmV5.Auth.PendingDecisionsTest do
  use ExUnit.Case, async: false

  alias ApmV5.Auth.PendingDecisions

  setup do
    # GenServer is already in the supervision tree — just ensure it's running
    assert Process.whereis(PendingDecisions) != nil
    :ok
  end

  describe "list_pending/0" do
    test "excludes expired entries" do
      # Insert an expired entry directly into ETS, bypassing the GenServer
      table = :agentlock_pending
      expired_id = "pending-test-expired-#{System.unique_integer([:positive])}"

      expired_entry = %{
        request_id: expired_id,
        tool_name: "Bash",
        session_id: "test-session",
        agent_id: "test-agent",
        risk_level: :high,
        params: %{},
        status: :pending,
        decision: nil,
        decided_at: nil,
        inserted_at: DateTime.utc_now(),
        # already expired 10 seconds ago
        expires_at: DateTime.add(DateTime.utc_now(), -10, :second)
      }

      :ets.insert(table, {expired_id, expired_entry})

      result = PendingDecisions.list_pending()
      ids = Enum.map(result, & &1.request_id)
      refute expired_id in ids,
             "Expected expired entry #{expired_id} to be excluded from list_pending/0"

      # Clean up
      :ets.delete(table, expired_id)
    end

    test "includes non-expired pending entries" do
      {:ok, request_id} =
        PendingDecisions.add("Write", "test-session-list", :high, "test-agent-list", %{})

      result = PendingDecisions.list_pending()
      ids = Enum.map(result, & &1.request_id)
      assert request_id in ids,
             "Expected #{request_id} to appear in list_pending/0"

      # Clean up
      PendingDecisions.decide(request_id, :deny)
    end

    test "excludes decided (approved/denied) entries" do
      {:ok, request_id} =
        PendingDecisions.add("Edit", "test-session-decided", :high, "test-agent-decided", %{})

      PendingDecisions.decide(request_id, :deny)

      result = PendingDecisions.list_pending()
      ids = Enum.map(result, & &1.request_id)
      refute request_id in ids,
             "Denied entry #{request_id} should not appear in list_pending/0"
    end
  end

  describe "decide/2 — token issuance on approve" do
    test "returns {:ok, token_id} or :ok on approve" do
      {:ok, request_id} =
        PendingDecisions.add("Edit", "test-session-approve", :high, "test-agent-approve", %{})

      result = PendingDecisions.decide(request_id, :approve)

      assert match?({:ok, _token_id}, result) or result == :ok,
             "Expected {:ok, token_id} or :ok, got: #{inspect(result)}"
    end

    test "returns :ok on deny" do
      {:ok, request_id} =
        PendingDecisions.add("Bash", "test-session-deny", :high, "test-agent-deny", %{})

      assert :ok == PendingDecisions.decide(request_id, :deny)
    end

    test "returns {:error, :not_found} for unknown request_id" do
      assert {:error, :not_found} ==
               PendingDecisions.decide("pending-nonexistent-id", :deny)
    end
  end

  describe "add/5" do
    test "returns {:ok, request_id} with pending- prefix" do
      {:ok, id} = PendingDecisions.add("Read", "s1", :high, "a1", %{})
      assert String.starts_with?(id, "pending-")
      # Clean up
      PendingDecisions.decide(id, :deny)
    end

    test "entry is immediately retrievable via get/1" do
      {:ok, id} = PendingDecisions.add("Bash", "s2", :high, "a2", %{"command" => "ls"})
      entry = PendingDecisions.get(id)
      assert entry != nil
      assert entry.tool_name == "Bash"
      assert entry.status == :pending
      assert entry.decision == nil
      # Clean up
      PendingDecisions.decide(id, :deny)
    end
  end
end
