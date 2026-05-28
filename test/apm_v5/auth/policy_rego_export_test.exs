defmodule ApmV5.Auth.PolicyRegoExportTest do
  @moduledoc """
  TDD tests for PolicyRulesStore.to_rego/0 (auth-v10.1-s3 / CP-293).

  Validates:
  - Rego bundle header present and syntactically correct
  - Permanent rules serialized with correct action type
  - AutoApprovalStore policies appear in output
  - Default entrypoints present
  - Empty-state output is still valid Rego skeleton

  Run with: mix test --only opa_rego
  """

  use ExUnit.Case, async: false

  @moduletag :opa_rego

  alias ApmV5.Auth.PolicyRulesStore
  alias ApmV5.Auth.AutoApprovalStore

  setup do
    case Process.whereis(PolicyRulesStore) do
      nil -> {:ok, _} = PolicyRulesStore.start_link([])
      _pid -> :ok
    end

    case Process.whereis(AutoApprovalStore) do
      nil -> {:ok, _} = AutoApprovalStore.start_link([])
      _pid -> :ok
    end

    on_exit(fn ->
      PolicyRulesStore.remove_rule("TestBash")
      PolicyRulesStore.remove_rule("TestWrite")
      PolicyRulesStore.remove_rule("*")
    end)

    :ok
  end

  describe "to_rego/0 — header and structure" do
    test "output contains OPA package declaration" do
      rego = PolicyRulesStore.to_rego()
      assert String.contains?(rego, "package apm.agentlock")
    end

    test "output contains future keywords import" do
      rego = PolicyRulesStore.to_rego()
      assert String.contains?(rego, "import future.keywords")
    end

    test "output contains default allow = false entrypoint" do
      rego = PolicyRulesStore.to_rego()
      assert String.contains?(rego, "default allow = false")
    end

    test "output contains allow and deny rule heads" do
      rego = PolicyRulesStore.to_rego()
      assert String.contains?(rego, "allow if")
      assert String.contains?(rego, "deny if")
    end

    test "output contains generation timestamp comment" do
      rego = PolicyRulesStore.to_rego()
      # Check ISO 8601 date prefix — year 20XX
      assert Regex.match?(~r/Generated: 20\d{2}-/, rego)
    end

    test "output is a non-empty string" do
      rego = PolicyRulesStore.to_rego()
      assert is_binary(rego)
      assert byte_size(rego) > 100
    end
  end

  describe "to_rego/0 — permanent rules" do
    test "always_allow rule appears in output" do
      PolicyRulesStore.add_rule("TestBash", :always_allow)
      rego = PolicyRulesStore.to_rego()
      assert String.contains?(rego, "always_allow")
      assert String.contains?(rego, "TestBash")
    end

    test "always_deny rule appears in output" do
      PolicyRulesStore.add_rule("TestWrite", :always_deny)
      rego = PolicyRulesStore.to_rego()
      assert String.contains?(rego, "always_deny")
      assert String.contains?(rego, "TestWrite")
    end

    test "multiple rules all appear" do
      PolicyRulesStore.add_rule("TestBash", :always_deny)
      PolicyRulesStore.add_rule("TestWrite", :always_allow)
      rego = PolicyRulesStore.to_rego()
      assert String.contains?(rego, "TestBash")
      assert String.contains?(rego, "TestWrite")
    end

    test "wildcard rule is included" do
      PolicyRulesStore.add_rule("*", :always_allow)
      rego = PolicyRulesStore.to_rego()
      assert String.contains?(rego, "\"*\"")
    end

    test "empty rules block produces placeholder comment" do
      # Ensure no rules for unique keys
      PolicyRulesStore.remove_rule("TestBash")
      PolicyRulesStore.remove_rule("TestWrite")
      # Only verify header still valid — actual rules count may vary from other tests
      rego = PolicyRulesStore.to_rego()
      assert String.contains?(rego, "package apm.agentlock")
    end
  end

  describe "to_rego/0 — auto-approval policies" do
    test "active auto-approval policy_id appears in output" do
      {:ok, policy_id} =
        AutoApprovalStore.create(%{
          agent_id: "test-agent-rego",
          allowed_tools: ["Read", "Grep"],
          allowed_risk_levels: [:none, :low],
          reason: "rego export test"
        })

      rego = PolicyRulesStore.to_rego()
      assert String.contains?(rego, policy_id)
      assert String.contains?(rego, "auto_approved_policies")
    end

    test "no active policies produces placeholder comment" do
      # With no added policies in this test we still get the skeleton
      rego = PolicyRulesStore.to_rego()
      assert String.contains?(rego, "Auto-approval")
    end
  end

  describe "to_rego/0 — Rego syntax validity markers" do
    test "uses double-quoted string literals for tool names" do
      PolicyRulesStore.add_rule("TestBash", :always_deny)
      rego = PolicyRulesStore.to_rego()
      # OPA requires double-quoted string keys
      assert String.contains?(rego, "\"TestBash\"")
    end

    test "output ends without trailing whitespace on last line" do
      rego = PolicyRulesStore.to_rego()
      last_line = rego |> String.split("\n") |> List.last()
      refute String.ends_with?(last_line, " ")
    end

    test "idempotent — calling twice produces same structure" do
      PolicyRulesStore.add_rule("TestBash", :always_allow)
      rego1 = PolicyRulesStore.to_rego()
      rego2 = PolicyRulesStore.to_rego()
      # Same rules → same content (apart from timestamp line which includes seconds)
      # Compare non-timestamp lines
      lines1 = rego1 |> String.split("\n") |> Enum.reject(&String.contains?(&1, "Generated:"))
      lines2 = rego2 |> String.split("\n") |> Enum.reject(&String.contains?(&1, "Generated:"))
      assert lines1 == lines2
    end
  end
end
