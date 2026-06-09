defmodule Apm.Auth.DelegationTokenTest do
  @moduledoc """
  TDD coverage for Apm.Auth.DelegationToken (v10.0.0/s2 CP-290 — OWASP MCP02 fix).

  Covers:
  - root token (no parent) issues with any scope
  - child token with strict subset of parent tools → ok
  - child token with extra tool not in parent → :exceeds_parent_ceiling
  - child token with higher risk ceiling than parent → :exceeds_parent_ceiling
  - child token with risk ceiling at-or-below parent → ok
  - verify accepts valid token
  - verify rejects expired token
  - verify rejects tampered signature
  - enforce_ceiling allows in-scope tool at allowed risk
  - enforce_ceiling rejects out-of-scope tool (:tool_not_allowed)
  - enforce_ceiling rejects in-scope tool at excessive risk (:risk_exceeds_ceiling)
  - enforce_ceiling rejects expired token
  """

  use ExUnit.Case, async: false

  alias Apm.Auth.DelegationToken
  alias Apm.Identity.KeyStore

  @tmp_key_file Path.join(System.tmp_dir!(), "delegation_token_test_key.pem")

  setup do
    File.rm(@tmp_key_file)
    {:ok, ks} = KeyStore.start_link(name: :delegation_test_ks, key_file: @tmp_key_file)

    on_exit(fn ->
      if Process.alive?(ks), do: GenServer.stop(ks)
      File.rm(@tmp_key_file)
    end)

    {:ok, keystore: ks}
  end

  describe "issue/3 — root tokens (no parent)" do
    test "root token can be issued with any scope", %{keystore: ks} do
      assert {:ok, token} =
               DelegationToken.issue(nil, "agent-root",
                 allowed_tools: ["Read", "Write", "Bash", "Edit", "WebFetch"],
                 max_risk_ceiling: :critical,
                 keystore: ks
               )

      assert token.parent_agent_id == nil
      assert token.child_agent_id == "agent-root"
      assert token.max_risk_ceiling == :critical
      assert "Bash" in token.allowed_tools
      assert is_binary(token.signature)
      # Ed25519 sig
      assert byte_size(token.signature) == 64
    end
  end

  describe "issue/3 — child tokens (with parent ceiling)" do
    setup %{keystore: ks} do
      {:ok, parent} =
        DelegationToken.issue(nil, "parent-1",
          allowed_tools: ["Read", "Write", "Bash", "Edit", "WebFetch"],
          max_risk_ceiling: :high,
          keystore: ks
        )

      {:ok, parent: parent}
    end

    test "child with subset of parent's tools and lower ceiling — ok", %{
      parent: parent,
      keystore: ks
    } do
      assert {:ok, child} =
               DelegationToken.issue(parent, "child-ok",
                 allowed_tools: ["Read", "Write", "Edit"],
                 max_risk_ceiling: :medium,
                 keystore: ks
               )

      assert child.parent_agent_id == "parent-1"
      assert child.allowed_tools -- parent.allowed_tools == []

      assert DelegationToken.risk_rank(child.max_risk_ceiling) <=
               DelegationToken.risk_rank(parent.max_risk_ceiling)
    end

    test "child with extra tool not in parent — :exceeds_parent_ceiling", %{
      parent: parent,
      keystore: ks
    } do
      # WebSearch is NOT in parent's allowed_tools
      assert {:error, :exceeds_parent_ceiling} =
               DelegationToken.issue(parent, "child-bad-tool",
                 allowed_tools: ["Read", "WebSearch"],
                 max_risk_ceiling: :low,
                 keystore: ks
               )
    end

    test "child with higher risk ceiling than parent — :exceeds_parent_ceiling", %{
      parent: parent,
      keystore: ks
    } do
      # parent ceiling is :high, child requests :critical
      assert {:error, :exceeds_parent_ceiling} =
               DelegationToken.issue(parent, "child-too-risky",
                 allowed_tools: ["Read"],
                 max_risk_ceiling: :critical,
                 keystore: ks
               )
    end

    test "child with same scope as parent — ok (allowed boundary)", %{
      parent: parent,
      keystore: ks
    } do
      assert {:ok, _child} =
               DelegationToken.issue(parent, "child-equal",
                 allowed_tools: parent.allowed_tools,
                 max_risk_ceiling: parent.max_risk_ceiling,
                 keystore: ks
               )
    end

    test "child of expired parent — :exceeds_parent_ceiling (expired = no scope)", %{keystore: ks} do
      {:ok, dead_parent} =
        DelegationToken.issue(nil, "dead-parent",
          allowed_tools: ["Read"],
          max_risk_ceiling: :low,
          ttl_seconds: -1,
          keystore: ks
        )

      assert {:error, reason} =
               DelegationToken.issue(dead_parent, "ghost-child",
                 allowed_tools: ["Read"],
                 max_risk_ceiling: :low,
                 keystore: ks
               )

      assert reason in [:exceeds_parent_ceiling, :parent_expired]
    end
  end

  describe "verify/2" do
    test "valid token verifies", %{keystore: ks} do
      {:ok, token} =
        DelegationToken.issue(nil, "v-1",
          allowed_tools: ["Read"],
          max_risk_ceiling: :low,
          keystore: ks
        )

      assert :ok = DelegationToken.verify(token, keystore: ks)
    end

    test "expired token rejected", %{keystore: ks} do
      {:ok, token} =
        DelegationToken.issue(nil, "v-exp",
          allowed_tools: ["Read"],
          max_risk_ceiling: :low,
          ttl_seconds: -1,
          keystore: ks
        )

      assert {:error, :token_expired} = DelegationToken.verify(token, keystore: ks)
    end

    test "tampered token rejected", %{keystore: ks} do
      {:ok, token} =
        DelegationToken.issue(nil, "v-t",
          allowed_tools: ["Read"],
          max_risk_ceiling: :low,
          keystore: ks
        )

      # Mutate allowed_tools but keep signature → should fail
      bad_token = %{token | allowed_tools: ["Read", "Bash"]}
      assert {:error, :invalid_signature} = DelegationToken.verify(bad_token, keystore: ks)
    end
  end

  describe "enforce_ceiling/3" do
    setup %{keystore: ks} do
      {:ok, token} =
        DelegationToken.issue(nil, "enforce-test",
          allowed_tools: ["Read", "Write", "Edit"],
          max_risk_ceiling: :medium,
          keystore: ks
        )

      {:ok, token: token}
    end

    test "allowed tool at allowed risk — :ok", %{token: token} do
      assert :ok = DelegationToken.enforce_ceiling(token, "Read", :low)
      assert :ok = DelegationToken.enforce_ceiling(token, "Edit", :medium)
    end

    test "disallowed tool — :tool_not_allowed", %{token: token} do
      assert {:error, :tool_not_allowed} = DelegationToken.enforce_ceiling(token, "Bash", :low)

      assert {:error, :tool_not_allowed} =
               DelegationToken.enforce_ceiling(token, "WebSearch", :none)
    end

    test "allowed tool but risk exceeds ceiling — :risk_exceeds_ceiling", %{token: token} do
      assert {:error, :risk_exceeds_ceiling} =
               DelegationToken.enforce_ceiling(token, "Read", :high)

      assert {:error, :risk_exceeds_ceiling} =
               DelegationToken.enforce_ceiling(token, "Write", :critical)
    end

    test "expired token rejected by enforce_ceiling", %{keystore: ks} do
      {:ok, expired} =
        DelegationToken.issue(nil, "expired",
          allowed_tools: ["Read"],
          max_risk_ceiling: :low,
          ttl_seconds: -1,
          keystore: ks
        )

      assert {:error, :token_expired} = DelegationToken.enforce_ceiling(expired, "Read", :low)
    end
  end

  describe "risk_rank/1 — ordered ceiling" do
    test "risk ordering is :none < :low < :medium < :high < :critical" do
      assert DelegationToken.risk_rank(:none) < DelegationToken.risk_rank(:low)
      assert DelegationToken.risk_rank(:low) < DelegationToken.risk_rank(:medium)
      assert DelegationToken.risk_rank(:medium) < DelegationToken.risk_rank(:high)
      assert DelegationToken.risk_rank(:high) < DelegationToken.risk_rank(:critical)
    end
  end
end
