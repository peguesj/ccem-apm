defmodule ApmV5.Auth.TypesTest do
  use ExUnit.Case, async: true

  alias ApmV5.Auth.Types

  # ── risk_levels/0 ──────────────────────────────────────────────────────────

  test "risk_levels returns ordered list" do
    assert Types.risk_levels() == [:none, :low, :medium, :high, :critical]
  end

  # ── valid_risk_level?/1 ────────────────────────────────────────────────────

  test "valid_risk_level? returns true for all valid levels" do
    assert Types.valid_risk_level?(:none)
    assert Types.valid_risk_level?(:low)
    assert Types.valid_risk_level?(:medium)
    assert Types.valid_risk_level?(:high)
    assert Types.valid_risk_level?(:critical)
  end

  test "valid_risk_level? returns false for invalid atoms" do
    refute Types.valid_risk_level?(:unknown)
    refute Types.valid_risk_level?(:extreme)
    refute Types.valid_risk_level?(:moderate)
  end

  # ── risk_severity/1 ────────────────────────────────────────────────────────

  test "risk_severity returns correct ordering" do
    assert Types.risk_severity(:none) == 0
    assert Types.risk_severity(:low) == 1
    assert Types.risk_severity(:medium) == 2
    assert Types.risk_severity(:high) == 3
    assert Types.risk_severity(:critical) == 4
  end

  test "risk_severity is strictly monotonic" do
    severities =
      Types.risk_levels()
      |> Enum.map(&Types.risk_severity/1)

    assert severities == Enum.sort(severities)
    assert length(Enum.uniq(severities)) == length(severities)
  end

  # ── trust_value/1 ──────────────────────────────────────────────────────────

  test "trust_value returns correct ordering" do
    assert Types.trust_value(:authoritative) == 2
    assert Types.trust_value(:derived) == 1
    assert Types.trust_value(:untrusted) == 0
  end

  # ── min_trust/2 ────────────────────────────────────────────────────────────

  test "min_trust returns lower trust level" do
    assert Types.min_trust(:authoritative, :derived) == :derived
    assert Types.min_trust(:derived, :authoritative) == :derived
    assert Types.min_trust(:untrusted, :authoritative) == :untrusted
    assert Types.min_trust(:authoritative, :untrusted) == :untrusted
  end

  test "min_trust is idempotent for same level" do
    assert Types.min_trust(:derived, :derived) == :derived
    assert Types.min_trust(:authoritative, :authoritative) == :authoritative
    assert Types.min_trust(:untrusted, :untrusted) == :untrusted
  end

  test "min_trust is commutative" do
    assert Types.min_trust(:authoritative, :untrusted) ==
             Types.min_trust(:untrusted, :authoritative)

    assert Types.min_trust(:derived, :untrusted) ==
             Types.min_trust(:untrusted, :derived)
  end

  # ── source_trust/1 ────────────────────────────────────────────────────────

  test "source_trust maps authoritative sources correctly" do
    assert Types.source_trust(:user_message) == :authoritative
    assert Types.source_trust(:system_prompt) == :authoritative
  end

  test "source_trust maps derived sources correctly" do
    assert Types.source_trust(:tool_output) == :derived
    assert Types.source_trust(:agent_reasoning) == :derived
    assert Types.source_trust(:file_content) == :derived
    assert Types.source_trust(:agent_memory) == :derived
    assert Types.source_trust(:peer_agent) == :derived
  end

  test "source_trust maps untrusted sources correctly" do
    assert Types.source_trust(:web_content) == :untrusted
  end

  # ── Struct defaults ────────────────────────────────────────────────────────

  test "AuthTool struct has correct defaults" do
    tool = %Types.AuthTool{}
    assert tool.requires_auth == true
    assert tool.allowed_roles == []
    assert tool.data_boundary == :authenticated_user_only
    assert tool.max_records == 100
    assert tool.rate_limit == nil
  end

  test "PolicyDecision struct has correct defaults" do
    decision = %Types.PolicyDecision{}
    assert decision.allowed == false
    assert decision.risk_level == :none
    assert decision.reason == nil
    assert decision.needs_approval == false
    assert decision.constraints == %{}
  end

  test "AuthSession struct has correct defaults" do
    session = %Types.AuthSession{}
    assert session.data_boundary == :authenticated_user_only
    assert session.trust_ceiling == :authoritative
    assert session.tool_call_count == 0
    assert session.denied_count == 0
    assert session.metadata == %{}
  end

  test "ExecutionToken struct has correct defaults" do
    token = %Types.ExecutionToken{}
    assert token.status == :active
    assert token.consumed_at == nil
  end

  test "RedactionResult struct has correct defaults" do
    result = %Types.RedactionResult{}
    assert result.redacted_text == ""
    assert result.redactions == []
    assert result.mode == :auto
    assert result.had_redactions == false
  end

  test "ContextEntry struct fields exist" do
    entry = %Types.ContextEntry{}
    assert Map.has_key?(entry, :id)
    assert Map.has_key?(entry, :session_id)
    assert Map.has_key?(entry, :agent_id)
    assert Map.has_key?(entry, :source)
    assert Map.has_key?(entry, :trust_level)
    assert Map.has_key?(entry, :content_hash)
    assert Map.has_key?(entry, :timestamp)
  end
end
