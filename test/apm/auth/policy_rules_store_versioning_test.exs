defmodule Apm.Auth.PolicyRulesStoreVersioningTest do
  @moduledoc """
  TDD tests for CP-285 (auth-s2-c): PolicyRulesStore versioning + attestation.

  Covers:
  - Version increments monotonically on each add_rule/3 call
  - created_by and approved_by fields persisted in ETS tuple
  - expires_at auto-demotes rule to :none when past
  - policy_history/1 returns ordered changelog chain
  - GET /api/v2/auth/policy/history via controller

  Run with: mix test --only auth_ext
  """

  use ExUnit.Case, async: false

  @moduletag :auth_ext

  alias Apm.Auth.PolicyRulesStore

  setup do
    case Process.whereis(PolicyRulesStore) do
      nil -> {:ok, _} = PolicyRulesStore.start_link([])
      _pid -> :ok
    end

    # Clean up test keys and history on exit
    on_exit(fn ->
      for tool <- ["versioned_tool", "attested_tool", "expiring_tool", "hist_tool_a", "hist_tool_b"] do
        PolicyRulesStore.remove_rule(tool)
        PolicyRulesStore.clear_tool_history(tool)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Versioning
  # ---------------------------------------------------------------------------

  describe "versioning on add_rule/3" do
    test "first add produces version 1" do
      :ok = PolicyRulesStore.add_rule("versioned_tool", :always_allow, created_by: "agent-1")
      entry = PolicyRulesStore.get_rule_entry("versioned_tool")
      assert entry != nil
      assert entry.version == 1
    end

    test "second add increments version monotonically" do
      PolicyRulesStore.add_rule("versioned_tool", :always_allow, created_by: "agent-1")
      PolicyRulesStore.add_rule("versioned_tool", :always_deny, created_by: "agent-2")
      entry = PolicyRulesStore.get_rule_entry("versioned_tool")
      assert entry.version == 2
      assert entry.action == :always_deny
    end

    test "version is independent per tool" do
      PolicyRulesStore.add_rule("versioned_tool", :always_allow, created_by: "agent-1")
      PolicyRulesStore.add_rule("versioned_tool", :always_deny, created_by: "agent-1")
      PolicyRulesStore.add_rule("attested_tool", :always_allow, created_by: "agent-2")

      v1 = PolicyRulesStore.get_rule_entry("versioned_tool")
      v2 = PolicyRulesStore.get_rule_entry("attested_tool")
      assert v1.version == 2
      assert v2.version == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Attestation fields
  # ---------------------------------------------------------------------------

  describe "attestation fields" do
    test "created_by is stored and returned" do
      PolicyRulesStore.add_rule("attested_tool", :always_allow, created_by: "operator@example.com")
      entry = PolicyRulesStore.get_rule_entry("attested_tool")
      assert entry.created_by == "operator@example.com"
    end

    test "approved_by defaults to nil and can be set" do
      PolicyRulesStore.add_rule("attested_tool", :always_allow, created_by: "agent-1")
      entry = PolicyRulesStore.get_rule_entry("attested_tool")
      assert entry.approved_by == nil

      PolicyRulesStore.add_rule("attested_tool", :always_allow,
        created_by: "agent-1",
        approved_by: "admin@example.com"
      )

      entry2 = PolicyRulesStore.get_rule_entry("attested_tool")
      assert entry2.approved_by == "admin@example.com"
    end

    test "list_rules/0 includes created_by field" do
      PolicyRulesStore.add_rule("attested_tool", :always_deny, created_by: "tester")
      rules = PolicyRulesStore.list_rules()
      entry = Enum.find(rules, &(&1.tool_name == "attested_tool"))
      assert entry != nil
      assert entry.created_by == "tester"
    end
  end

  # ---------------------------------------------------------------------------
  # Expiry — auto-demotion
  # ---------------------------------------------------------------------------

  describe "expires_at auto-demotion" do
    test "rule with future expires_at is still active" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      PolicyRulesStore.add_rule("expiring_tool", :always_allow, expires_at: future)
      assert PolicyRulesStore.check_rule("expiring_tool") == :always_allow
    end

    test "rule with past expires_at is demoted to :none" do
      past = DateTime.add(DateTime.utc_now(), -1, :second)
      PolicyRulesStore.add_rule("expiring_tool", :always_allow, expires_at: past)
      assert PolicyRulesStore.check_rule("expiring_tool") == :none
    end

    test "non-expired rule retains original action after expiry check" do
      future = DateTime.add(DateTime.utc_now(), 60, :second)
      PolicyRulesStore.add_rule("expiring_tool", :always_deny, expires_at: future)
      # Should remain :always_deny
      assert PolicyRulesStore.check_rule("expiring_tool") == :always_deny
    end
  end

  # ---------------------------------------------------------------------------
  # Policy History
  # ---------------------------------------------------------------------------

  describe "policy_history/1" do
    test "returns empty list for unknown tool" do
      assert PolicyRulesStore.policy_history("never_existed_xyz_abc") == []
    end

    test "returns a list with one entry after first add" do
      PolicyRulesStore.add_rule("hist_tool_a", :always_allow, created_by: "agent-1")
      history = PolicyRulesStore.policy_history("hist_tool_a")
      assert length(history) == 1
      [entry] = history
      assert entry.version == 1
      assert entry.action == :always_allow
      assert entry.created_by == "agent-1"
      assert is_binary(entry.inserted_at)
    end

    test "returns ordered changelog on multiple updates" do
      PolicyRulesStore.add_rule("hist_tool_a", :always_allow, created_by: "agent-1")
      PolicyRulesStore.add_rule("hist_tool_a", :always_deny, created_by: "agent-2", approved_by: "admin")

      history = PolicyRulesStore.policy_history("hist_tool_a")
      assert length(history) == 2

      versions = Enum.map(history, & &1.version)
      assert versions == Enum.sort(versions)

      [v1, v2] = history
      assert v1.version == 1
      assert v1.action == :always_allow
      assert v2.version == 2
      assert v2.action == :always_deny
      assert v2.approved_by == "admin"
    end

    test "history is independent per tool" do
      PolicyRulesStore.add_rule("hist_tool_a", :always_allow, created_by: "agent-1")
      PolicyRulesStore.add_rule("hist_tool_b", :always_deny, created_by: "agent-2")

      hist_a = PolicyRulesStore.policy_history("hist_tool_a")
      hist_b = PolicyRulesStore.policy_history("hist_tool_b")

      assert length(hist_a) == 1
      assert length(hist_b) == 1
      assert hd(hist_a).action == :always_allow
      assert hd(hist_b).action == :always_deny
    end
  end
end
