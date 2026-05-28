defmodule ApmV5.Governance.GovernanceKriTelemetryTest do
  @moduledoc """
  Smoke tests for the 6 governance KRI telemetry events introduced in
  comp-ms1 / CP-232 / US-464.

  Each test attaches a single-use handler via `:telemetry.attach/4`, fires the
  relevant event or triggers the call site under test, then asserts the handler
  received the expected event with the correct measurement keys.

  Tests are `async: false` because PolicyDecisionStore uses global ETS and
  GovernanceKriPoller is a named GenServer.
  """

  use ExUnit.Case, async: false

  alias ApmV5.Auth.{PolicyDecisionStore, PolicyRulesStore}
  alias ApmV5.Governance.GovernanceKriPoller

  # ---------------------------------------------------------------------------
  # Helper: attach a one-shot telemetry handler; return a ref to assert on.
  # ---------------------------------------------------------------------------

  defp attach_once(event_name) do
    ref = make_ref()
    test_pid = self()
    handler_id = "test-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      event_name,
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_fired, ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  # ---------------------------------------------------------------------------
  # 1. denial_rate
  # ---------------------------------------------------------------------------

  @tag :governance_kri
  test "denial_rate fires when :telemetry.execute is called directly" do
    ref = attach_once([:apm_v5, :governance, :denial_rate])

    :telemetry.execute(
      [:apm_v5, :governance, :denial_rate],
      %{count: 1},
      %{tool_name: "Bash", agent_id: "test-agent", session_id: "ses-1", reason: :always_deny_rule}
    )

    assert_receive {:telemetry_fired, ^ref, %{count: 1}, meta}, 500
    assert meta.tool_name == "Bash"
    assert meta.reason == :always_deny_rule
  end

  # ---------------------------------------------------------------------------
  # 2. escalation_rate
  # ---------------------------------------------------------------------------

  @tag :governance_kri
  test "escalation_rate fires when :telemetry.execute is called directly" do
    ref = attach_once([:apm_v5, :governance, :escalation_rate])

    :telemetry.execute(
      [:apm_v5, :governance, :escalation_rate],
      %{count: 1},
      %{tool_name: "Write", agent_id: "test-agent", session_id: "ses-2"}
    )

    assert_receive {:telemetry_fired, ^ref, %{count: 1}, meta}, 500
    assert meta.tool_name == "Write"
  end

  # ---------------------------------------------------------------------------
  # 3. critical_command_rate
  # ---------------------------------------------------------------------------

  @tag :governance_kri
  test "critical_command_rate fires when :telemetry.execute is called directly" do
    ref = attach_once([:apm_v5, :governance, :critical_command_rate])

    :telemetry.execute(
      [:apm_v5, :governance, :critical_command_rate],
      %{count: 1},
      %{tool_name: "Bash", agent_id: "test-agent", command_signature: "rm -rf /tmp/test"}
    )

    assert_receive {:telemetry_fired, ^ref, %{count: 1}, meta}, 500
    assert meta.command_signature == "rm -rf /tmp/test"
  end

  # ---------------------------------------------------------------------------
  # 4. trust_degradation_events
  # ---------------------------------------------------------------------------

  @tag :governance_kri
  test "trust_degradation_events fires when :telemetry.execute is called directly" do
    ref = attach_once([:apm_v5, :governance, :trust_degradation_events])

    :telemetry.execute(
      [:apm_v5, :governance, :trust_degradation_events],
      %{count: 1, from_level: :authoritative, to_level: :derived},
      %{session_id: "ses-3"}
    )

    assert_receive {:telemetry_fired, ^ref, measurements, meta}, 500
    assert measurements.from_level == :authoritative
    assert measurements.to_level == :derived
    assert meta.session_id == "ses-3"
  end

  # ---------------------------------------------------------------------------
  # 5. policy_rule_changes — via PolicyRulesStore
  # ---------------------------------------------------------------------------

  @tag :governance_kri
  test "policy_rule_changes fires on PolicyRulesStore.add_rule/2" do
    ref = attach_once([:apm_v5, :governance, :policy_rule_changes])

    tool = "TestTool-#{System.unique_integer([:positive])}"
    PolicyRulesStore.add_rule(tool, :always_deny)

    assert_receive {:telemetry_fired, ^ref, %{count: 1}, meta}, 1000
    assert meta.change_type == :upsert
    assert meta.tool_name == tool

    # Cleanup
    PolicyRulesStore.remove_rule(tool)
  end

  @tag :governance_kri
  test "policy_rule_changes fires on PolicyRulesStore.remove_rule/1" do
    tool = "TestTool-remove-#{System.unique_integer([:positive])}"
    PolicyRulesStore.add_rule(tool, :always_allow)

    ref = attach_once([:apm_v5, :governance, :policy_rule_changes])
    PolicyRulesStore.remove_rule(tool)

    assert_receive {:telemetry_fired, ^ref, %{count: 1}, meta}, 1000
    assert meta.change_type == :delete
    assert meta.tool_name == tool
  end

  # ---------------------------------------------------------------------------
  # 6. risk_score_p95 — via GovernanceKriPoller.emit_now/0
  # ---------------------------------------------------------------------------

  @tag :governance_kri
  test "risk_score_p95 fires via GovernanceKriPoller.emit_now/0" do
    PolicyDecisionStore.clear()

    # Seed a handful of decisions
    for risk <- [:none, :low, :medium, :high, :critical] do
      PolicyDecisionStore.record_decision(%{
        agent_id: "smoke-agent",
        session_id: "smoke-ses",
        tool_name: "Bash",
        risk_level: risk,
        outcome: :allow
      })
    end

    # Wait for async records to be stored
    :timer.sleep(50)

    ref = attach_once([:apm_v5, :governance, :risk_score_p95])
    GovernanceKriPoller.emit_now()

    assert_receive {:telemetry_fired, ^ref, %{value: value}, %{sample_size: size}}, 2000
    assert is_float(value)
    assert value >= 0.0 and value <= 4.0
    assert size >= 5

    PolicyDecisionStore.clear()
  end
end
