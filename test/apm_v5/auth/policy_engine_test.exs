defmodule ApmV5.Auth.PolicyEngineTest do
  use ExUnit.Case, async: true

  alias ApmV5.Auth.PolicyEngine

  # ── default_risk/1 ──────────────────────────────────────────────────────────

  test "default_risk returns :none for read-only tools" do
    assert PolicyEngine.default_risk("Read") == :none
    assert PolicyEngine.default_risk("Grep") == :none
    assert PolicyEngine.default_risk("Glob") == :none
    assert PolicyEngine.default_risk("LS") == :none
  end

  test "default_risk returns :low for agent/web tools" do
    assert PolicyEngine.default_risk("Agent") == :low
    assert PolicyEngine.default_risk("WebFetch") == :low
    assert PolicyEngine.default_risk("WebSearch") == :low
  end

  test "default_risk returns :medium for write tools" do
    assert PolicyEngine.default_risk("Write") == :medium
    assert PolicyEngine.default_risk("Edit") == :medium
    assert PolicyEngine.default_risk("NotebookEdit") == :medium
    assert PolicyEngine.default_risk("Skill") == :medium
  end

  test "default_risk returns :high for Bash" do
    assert PolicyEngine.default_risk("Bash") == :high
  end

  test "default_risk returns :low for unknown tools" do
    assert PolicyEngine.default_risk("unknown") == :low
    assert PolicyEngine.default_risk("SomeFutureTool") == :low
  end

  # ── default_risk_map/0 ─────────────────────────────────────────────────────

  test "default_risk_map returns a map with all known tools" do
    map = PolicyEngine.default_risk_map()
    assert is_map(map)
    assert Map.has_key?(map, "Read")
    assert Map.has_key?(map, "Bash")
    assert Map.has_key?(map, "Write")
    assert map_size(map) >= 15
  end

  # ── evaluate/2-3 ───────────────────────────────────────────────────────────

  test "evaluate auto-permits :none risk tools" do
    decision = PolicyEngine.evaluate("Read", "agent")
    assert decision.allowed == true
    assert decision.risk_level == :none
    assert decision.needs_approval == false
  end

  test "evaluate permits :low risk with default context" do
    decision = PolicyEngine.evaluate("Agent", "agent")
    assert decision.allowed == true
    assert decision.risk_level == :low
    assert decision.needs_approval == false
  end

  test "evaluate permits :medium risk with default context" do
    decision = PolicyEngine.evaluate("Write", "agent")
    assert decision.allowed == true
    assert decision.risk_level == :medium
  end

  test "evaluate requires approval for :high risk" do
    decision = PolicyEngine.evaluate("Bash", "agent")
    assert decision.needs_approval == true
    assert decision.risk_level == :high
    assert decision.allowed == false
  end

  test "evaluate escalates Bash to :critical for destructive commands" do
    context = %{params: %{"command" => "rm -rf /"}}
    decision = PolicyEngine.evaluate("Bash", "agent", context)
    assert decision.risk_level == :critical
    assert decision.needs_approval == true
    assert decision.allowed == false
  end

  test "evaluate returns PolicyDecision struct" do
    decision = PolicyEngine.evaluate("Grep", "agent")
    assert %ApmV5.Auth.Types.PolicyDecision{} = decision
    assert Map.has_key?(decision, :allowed)
    assert Map.has_key?(decision, :risk_level)
    assert Map.has_key?(decision, :detail)
    assert Map.has_key?(decision, :needs_approval)
  end

  test "evaluate with untrusted trust ceiling blocks medium risk" do
    context = %{trust_ceiling: :untrusted}
    decision = PolicyEngine.evaluate("Write", "agent", context)
    assert decision.allowed == false
    assert decision.reason == :trust_degraded
  end

  test "evaluate with derived trust requires approval for high risk" do
    context = %{trust_ceiling: :derived}
    decision = PolicyEngine.evaluate("Bash", "agent", context)
    assert decision.allowed == false
    assert decision.needs_approval == true
  end

  # ── destructive_command?/1 ─────────────────────────────────────────────────

  test "destructive_command? detects rm -rf" do
    assert PolicyEngine.destructive_command?("rm -rf /")
    assert PolicyEngine.destructive_command?("rm -rf /tmp/dir")
  end

  test "destructive_command? detects git push --force" do
    assert PolicyEngine.destructive_command?("git push --force")
    assert PolicyEngine.destructive_command?("git push --force origin main")
  end

  test "destructive_command? detects git reset --hard" do
    assert PolicyEngine.destructive_command?("git reset --hard")
  end

  test "destructive_command? detects kill -9" do
    assert PolicyEngine.destructive_command?("kill -9 12345")
    assert PolicyEngine.destructive_command?("pkill -9 beam")
  end

  test "destructive_command? detects SQL drop commands" do
    assert PolicyEngine.destructive_command?("DROP TABLE users")
    assert PolicyEngine.destructive_command?("drop database production")
  end

  test "destructive_command? returns false for safe commands" do
    refute PolicyEngine.destructive_command?("ls -la")
    refute PolicyEngine.destructive_command?("git status")
    refute PolicyEngine.destructive_command?("mix test")
    refute PolicyEngine.destructive_command?("echo hello")
  end
end
