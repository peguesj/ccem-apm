defmodule ApmV5.Auth.AutoApprovalStoreTest do
  use ExUnit.Case

  alias ApmV5.Auth.AutoApprovalStore

  setup do
    # Clear ETS table before each test
    :ets.delete_all_objects(:auto_approval_policies)
    :ok
  end

  describe "create/1" do
    test "creates a new auto-approval policy" do
      {:ok, policy_id} = AutoApprovalStore.create(%{
        agent_id: "ag-123",
        allowed_tools: ["Read", "Edit"],
        allowed_risk_levels: [:low, :medium],
        reason: "development session"
      })

      assert is_binary(policy_id)
      assert String.starts_with?(policy_id, "ap-")
    end

    test "creates policy with default values" do
      {:ok, policy_id} = AutoApprovalStore.create(%{
        agent_id: "ag-123"
      })

      policy = AutoApprovalStore.get(policy_id)
      assert policy.allowed_tools == :all
      assert policy.allowed_risk_levels == :all
      assert policy.created_by == "system"
    end

    test "creates policy with all scope fields" do
      {:ok, policy_id} = AutoApprovalStore.create(%{
        agent_id: "ag-123",
        formation_id: "fm-456",
        session_id: "sess-789",
        project: "ccem",
        allowed_tools: :all,
        allowed_risk_levels: :all,
        reason: "multi-scope test"
      })

      policy = AutoApprovalStore.get(policy_id)
      assert policy.agent_id == "ag-123"
      assert policy.formation_id == "fm-456"
      assert policy.session_id == "sess-789"
      assert policy.project == "ccem"
    end
  end

  describe "list_active/0" do
    test "returns empty list when no policies exist" do
      policies = AutoApprovalStore.list_active()
      assert policies == []
    end

    test "returns active policies sorted by updated_at descending" do
      {:ok, _id1} = AutoApprovalStore.create(%{agent_id: "ag-1", reason: "first"})
      Process.sleep(10)
      {:ok, id2} = AutoApprovalStore.create(%{agent_id: "ag-2", reason: "second"})

      policies = AutoApprovalStore.list_active()
      assert length(policies) == 2
      # Most recent first
      assert List.first(policies).policy_id == id2
    end

    test "excludes expired policies" do
      now = DateTime.utc_now()
      past = DateTime.add(now, -10, :second)
      future = DateTime.add(now, 3600, :second)

      # Create one that has already expired
      {:ok, _id1} = AutoApprovalStore.create(%{
        agent_id: "ag-1",
        active_from: past,
        expires_at: past
      })

      # Create one that is active
      {:ok, id2} = AutoApprovalStore.create(%{
        agent_id: "ag-2",
        active_from: now,
        expires_at: future
      })

      policies = AutoApprovalStore.list_active()
      assert length(policies) == 1
      assert List.first(policies).policy_id == id2
    end
  end

  describe "find_matching/6" do
    test "returns nil when no policies match" do
      {:ok, _id} = AutoApprovalStore.create(%{
        agent_id: "ag-123",
        allowed_tools: ["Read"],
        allowed_risk_levels: [:low]
      })

      result = AutoApprovalStore.find_matching(
        "ag-456",  # Different agent
        nil,
        nil,
        nil,
        "Edit",
        :medium
      )

      assert result == nil
    end

    test "matches policy by agent_id" do
      {:ok, id} = AutoApprovalStore.create(%{
        agent_id: "ag-123",
        allowed_tools: :all,
        allowed_risk_levels: :all
      })

      result = AutoApprovalStore.find_matching(
        "ag-123",
        nil,
        nil,
        nil,
        "Read",
        :low
      )

      assert result.policy_id == id
    end

    test "matches policy with nil agent_id (any agent)" do
      {:ok, id} = AutoApprovalStore.create(%{
        agent_id: nil,
        allowed_tools: :all,
        allowed_risk_levels: :all
      })

      result = AutoApprovalStore.find_matching(
        "any-agent",
        nil,
        nil,
        nil,
        "Read",
        :low
      )

      assert result.policy_id == id
    end

    test "matches specific tools" do
      {:ok, id} = AutoApprovalStore.create(%{
        agent_id: "ag-123",
        allowed_tools: ["Read", "Glob"],
        allowed_risk_levels: :all
      })

      # Matching tool
      result = AutoApprovalStore.find_matching(
        "ag-123",
        nil,
        nil,
        nil,
        "Read",
        :low
      )

      assert result.policy_id == id

      # Non-matching tool
      result = AutoApprovalStore.find_matching(
        "ag-123",
        nil,
        nil,
        nil,
        "Bash",
        :low
      )

      assert result == nil
    end

    test "respects risk level ceiling" do
      {:ok, id} = AutoApprovalStore.create(%{
        agent_id: "ag-123",
        allowed_tools: :all,
        allowed_risk_levels: [:low, :medium]
      })

      # Within ceiling
      result = AutoApprovalStore.find_matching(
        "ag-123",
        nil,
        nil,
        nil,
        "Edit",
        :medium
      )

      assert result.policy_id == id

      # Above ceiling
      result = AutoApprovalStore.find_matching(
        "ag-123",
        nil,
        nil,
        nil,
        "Bash",
        :high
      )

      assert result == nil
    end

    test "applies scope hierarchy (agent > formation > session > project)" do
      # Create policies at different specificity levels
      {:ok, _agent_id} = AutoApprovalStore.create(%{
        agent_id: "ag-123",
        allowed_tools: :all,
        allowed_risk_levels: :all,
        reason: "agent-level"
      })

      {:ok, _formation_id} = AutoApprovalStore.create(%{
        agent_id: nil,
        formation_id: "fm-456",
        allowed_tools: :all,
        allowed_risk_levels: :all,
        reason: "formation-level"
      })

      {:ok, _project_id} = AutoApprovalStore.create(%{
        agent_id: nil,
        formation_id: nil,
        project: "ccem",
        allowed_tools: :all,
        allowed_risk_levels: :all,
        reason: "project-level"
      })

      # Most specific (agent) should win
      result = AutoApprovalStore.find_matching(
        "ag-123",
        "fm-456",
        nil,
        "ccem",
        "Read",
        :low
      )

      assert result.reason == "agent-level"
    end

    test "applies formation > session > project precedence when agent doesn't match" do
      {:ok, _proj_id} = AutoApprovalStore.create(%{
        agent_id: nil,
        formation_id: nil,
        project: "ccem",
        allowed_tools: :all,
        allowed_risk_levels: :all,
        reason: "project-level"
      })

      {:ok, _form_id} = AutoApprovalStore.create(%{
        agent_id: nil,
        formation_id: "fm-456",
        allowed_tools: :all,
        allowed_risk_levels: :all,
        reason: "formation-level"
      })

      # Formation should win over project
      result = AutoApprovalStore.find_matching(
        "any-agent",
        "fm-456",
        nil,
        "ccem",
        "Read",
        :low
      )

      assert result.reason == "formation-level"
    end

    test "uses most recent policy when specificity is equal" do
      {:ok, _id1} = AutoApprovalStore.create(%{
        agent_id: "ag-123",
        allowed_tools: :all,
        allowed_risk_levels: :all,
        reason: "older"
      })

      Process.sleep(10)

      {:ok, id2} = AutoApprovalStore.create(%{
        agent_id: "ag-123",
        allowed_tools: :all,
        allowed_risk_levels: :all,
        reason: "newer"
      })

      result = AutoApprovalStore.find_matching(
        "ag-123",
        nil,
        nil,
        nil,
        "Read",
        :low
      )

      # Most recent should be returned
      assert result.policy_id == id2
    end
  end

  describe "get/1" do
    test "returns a policy by ID" do
      {:ok, policy_id} = AutoApprovalStore.create(%{agent_id: "ag-123"})
      policy = AutoApprovalStore.get(policy_id)

      assert policy.policy_id == policy_id
      assert policy.agent_id == "ag-123"
    end

    test "returns nil for non-existent policy" do
      policy = AutoApprovalStore.get("ap-nonexistent")
      assert policy == nil
    end
  end

  describe "update/2" do
    test "updates an existing policy" do
      {:ok, policy_id} = AutoApprovalStore.create(%{
        agent_id: "ag-123",
        reason: "original"
      })

      {:ok, updated} = AutoApprovalStore.update(policy_id, %{
        reason: "updated reason"
      })

      assert updated.reason == "updated reason"
      assert updated.policy_id == policy_id
    end

    test "updates allowed_tools" do
      {:ok, policy_id} = AutoApprovalStore.create(%{
        agent_id: "ag-123",
        allowed_tools: ["Read"]
      })

      {:ok, updated} = AutoApprovalStore.update(policy_id, %{
        allowed_tools: ["Read", "Write"]
      })

      assert updated.allowed_tools == ["Read", "Write"]
    end

    test "returns error for non-existent policy" do
      result = AutoApprovalStore.update("ap-nonexistent", %{reason: "test"})
      assert result == {:error, :not_found}
    end

    test "updates updated_at timestamp" do
      {:ok, policy_id} = AutoApprovalStore.create(%{agent_id: "ag-123"})
      policy = AutoApprovalStore.get(policy_id)
      original_updated = policy.updated_at

      Process.sleep(10)

      {:ok, updated} = AutoApprovalStore.update(policy_id, %{reason: "new"})
      assert DateTime.after?(updated.updated_at, original_updated)
    end
  end

  describe "delete/1" do
    test "deletes a policy" do
      {:ok, policy_id} = AutoApprovalStore.create(%{agent_id: "ag-123"})

      :ok = AutoApprovalStore.delete(policy_id)
      assert AutoApprovalStore.get(policy_id) == nil
    end

    test "returns error for non-existent policy" do
      result = AutoApprovalStore.delete("ap-nonexistent")
      assert result == {:error, :not_found}
    end
  end

  describe "increment_approval_count/1" do
    test "increments approval counter" do
      {:ok, policy_id} = AutoApprovalStore.create(%{agent_id: "ag-123"})
      policy = AutoApprovalStore.get(policy_id)
      assert policy.approval_count == 0

      :ok = AutoApprovalStore.increment_approval_count(policy_id)
      updated = AutoApprovalStore.get(policy_id)
      assert updated.approval_count == 1

      :ok = AutoApprovalStore.increment_approval_count(policy_id)
      updated = AutoApprovalStore.get(policy_id)
      assert updated.approval_count == 2
    end

    test "returns error for non-existent policy" do
      result = AutoApprovalStore.increment_approval_count("ap-nonexistent")
      assert result == {:error, :not_found}
    end
  end

  describe "ttl expiration" do
    test "policies are automatically expired after TTL" do
      # This is a basic test; full TTL behavior is tested via integration
      {:ok, policy_id} = AutoApprovalStore.create(%{
        agent_id: "ag-123",
        reason: "will expire"
      })

      policy = AutoApprovalStore.get(policy_id)
      # Default TTL is 3600 seconds (1 hour)
      assert DateTime.diff(policy.expires_at, policy.active_from, :second) == 3600
    end

    test "custom expiration time is respected" do
      now = DateTime.utc_now()
      custom_expiry = DateTime.add(now, 1800, :second)  # 30 minutes

      {:ok, policy_id} = AutoApprovalStore.create(%{
        agent_id: "ag-123",
        expires_at: custom_expiry
      })

      policy = AutoApprovalStore.get(policy_id)
      assert DateTime.diff(policy.expires_at, custom_expiry, :second) == 0
    end
  end

  describe "scope matching AND logic" do
    test "all specified scopes must match (AND logic)" do
      {:ok, id} = AutoApprovalStore.create(%{
        agent_id: "ag-123",
        formation_id: "fm-456",
        session_id: "sess-789",
        allowed_tools: :all,
        allowed_risk_levels: :all
      })

      # All scopes match
      result = AutoApprovalStore.find_matching(
        "ag-123",
        "fm-456",
        "sess-789",
        nil,
        "Read",
        :low
      )

      assert result.policy_id == id

      # Agent doesn't match
      result = AutoApprovalStore.find_matching(
        "ag-999",  # Different
        "fm-456",
        "sess-789",
        nil,
        "Read",
        :low
      )

      assert result == nil

      # Formation doesn't match
      result = AutoApprovalStore.find_matching(
        "ag-123",
        "fm-999",  # Different
        "sess-789",
        nil,
        "Read",
        :low
      )

      assert result == nil

      # Session doesn't match
      result = AutoApprovalStore.find_matching(
        "ag-123",
        "fm-456",
        "sess-999",  # Different
        nil,
        "Read",
        :low
      )

      assert result == nil
    end
  end
end
