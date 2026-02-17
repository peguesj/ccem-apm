defmodule ApmV4.AlertRulesEngineTest do
  use ExUnit.Case, async: false

  alias ApmV4.AlertRulesEngine

  setup do
    # Re-bootstrap default rules (clears and re-populates ETS tables via GenServer)
    GenServer.call(AlertRulesEngine, :reinit)
    :ok
  end

  describe "bootstrap rules" do
    test "creates 3 default rules on init" do
      rules = AlertRulesEngine.list_rules()
      assert length(rules) == 3

      ids = Enum.map(rules, & &1.id) |> Enum.sort()
      assert ids == ["agent_offline", "fleet_error_rate", "token_spike"]
    end

    test "fleet_error_rate has correct config" do
      rule = AlertRulesEngine.get_rule("fleet_error_rate")
      assert rule.metric == "error_rate"
      assert rule.scope == :fleet
      assert rule.threshold == 0.10
      assert rule.comparator == :gt
      assert rule.window_s == 300
      assert rule.consecutive_breaches == 2
      assert rule.severity == :warning
    end

    test "agent_offline has correct config" do
      rule = AlertRulesEngine.get_rule("agent_offline")
      assert rule.metric == "heartbeat_gap"
      assert rule.scope == :agent
      assert rule.threshold == 300
      assert rule.consecutive_breaches == 1
      assert rule.severity == :critical
    end

    test "token_spike has correct config" do
      rule = AlertRulesEngine.get_rule("token_spike")
      assert rule.metric == "token_usage"
      assert rule.scope == :fleet
      assert rule.threshold == 100_000
      assert rule.severity == :info
    end
  end

  describe "add_rule/1 and list_rules/0" do
    test "adds a custom rule" do
      {:ok, rule_id} =
        AlertRulesEngine.add_rule(%{
          id: "custom_rule",
          name: "Custom Rule",
          metric: "cpu_usage",
          scope: :agent,
          threshold: 90,
          comparator: :gte,
          severity: :warning
        })

      assert rule_id == "custom_rule"
      assert length(AlertRulesEngine.list_rules()) == 4

      rule = AlertRulesEngine.get_rule("custom_rule")
      assert rule.metric == "cpu_usage"
      assert rule.threshold == 90
    end

    test "generates id when not provided" do
      {:ok, rule_id} =
        AlertRulesEngine.add_rule(%{
          name: "Auto ID Rule",
          metric: "mem",
          scope: :fleet,
          threshold: 50
        })

      assert is_binary(rule_id)
      assert String.length(rule_id) > 0
    end
  end

  describe "evaluate/3" do
    test "fires alert when threshold breached with consecutive_breaches=1" do
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:alerts")

      # token_spike: threshold=100000, consecutive=1
      AlertRulesEngine.evaluate("token_usage", :fleet, 200_000)

      assert_receive {:alert_fired, alert}, 1000
      assert alert.rule_id == "token_spike"
      assert alert.value == 200_000
    end

    test "consecutive_breaches requires N breaches before firing" do
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:alerts")

      # fleet_error_rate: consecutive_breaches=2
      AlertRulesEngine.evaluate("error_rate", :fleet, 0.20)
      refute_receive {:alert_fired, _}, 100

      AlertRulesEngine.evaluate("error_rate", :fleet, 0.20)
      assert_receive {:alert_fired, alert}, 1000
      assert alert.rule_id == "fleet_error_rate"
    end

    test "breach count resets on normal value" do
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:alerts")

      # fleet_error_rate: consecutive_breaches=2, threshold=0.10
      AlertRulesEngine.evaluate("error_rate", :fleet, 0.20)
      refute_receive {:alert_fired, _}, 100

      # Normal value resets count
      AlertRulesEngine.evaluate("error_rate", :fleet, 0.05)
      refute_receive {:alert_fired, _}, 100

      # Need 2 consecutive again
      AlertRulesEngine.evaluate("error_rate", :fleet, 0.20)
      refute_receive {:alert_fired, _}, 100

      AlertRulesEngine.evaluate("error_rate", :fleet, 0.20)
      assert_receive {:alert_fired, _}, 1000
    end

    test "does not fire for disabled rules" do
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:alerts")

      AlertRulesEngine.disable_rule("token_spike")
      AlertRulesEngine.evaluate("token_usage", :fleet, 200_000)
      refute_receive {:alert_fired, _}, 100
    end

    test "does not fire when value is below threshold" do
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:alerts")

      AlertRulesEngine.evaluate("token_usage", :fleet, 50_000)
      refute_receive {:alert_fired, _}, 100
    end
  end

  describe "get_alert_history/1" do
    test "returns fired alerts" do
      AlertRulesEngine.evaluate("token_usage", :fleet, 200_000)

      history = AlertRulesEngine.get_alert_history()
      assert length(history) == 1
      assert hd(history).rule_id == "token_spike"
    end

    test "filters by rule_id" do
      AlertRulesEngine.evaluate("token_usage", :fleet, 200_000)
      AlertRulesEngine.evaluate("heartbeat_gap", :agent, 500)

      history = AlertRulesEngine.get_alert_history(rule_id: "token_spike")
      assert length(history) == 1
      assert hd(history).rule_id == "token_spike"
    end

    test "filters by severity" do
      AlertRulesEngine.evaluate("token_usage", :fleet, 200_000)
      AlertRulesEngine.evaluate("heartbeat_gap", :agent, 500)

      history = AlertRulesEngine.get_alert_history(severity: :critical)
      assert Enum.all?(history, &(&1.severity == :critical))
    end

    test "respects limit" do
      for _ <- 1..5 do
        AlertRulesEngine.evaluate("token_usage", :fleet, 200_000)
      end

      history = AlertRulesEngine.get_alert_history(limit: 2)
      assert length(history) == 2
    end
  end

  describe "acknowledge/1" do
    test "marks alert as acknowledged" do
      AlertRulesEngine.evaluate("token_usage", :fleet, 200_000)
      [alert] = AlertRulesEngine.get_alert_history()
      assert alert.acknowledged == false

      assert :ok = AlertRulesEngine.acknowledge(alert.id)

      [updated] = AlertRulesEngine.get_alert_history()
      assert updated.acknowledged == true
    end

    test "returns error for unknown alert" do
      assert {:error, :not_found} = AlertRulesEngine.acknowledge("nonexistent")
    end
  end

  describe "delete_rule/1" do
    test "removes a rule" do
      assert :ok = AlertRulesEngine.delete_rule("token_spike")
      assert is_nil(AlertRulesEngine.get_rule("token_spike"))
      assert length(AlertRulesEngine.list_rules()) == 2
    end

    test "returns error for unknown rule" do
      assert {:error, :not_found} = AlertRulesEngine.delete_rule("nonexistent")
    end
  end

  describe "enable/disable toggling" do
    test "disable then enable a rule" do
      assert :ok = AlertRulesEngine.disable_rule("token_spike")
      rule = AlertRulesEngine.get_rule("token_spike")
      assert rule.enabled == false

      assert :ok = AlertRulesEngine.enable_rule("token_spike")
      rule = AlertRulesEngine.get_rule("token_spike")
      assert rule.enabled == true
    end

    test "returns error for unknown rule" do
      assert {:error, :not_found} = AlertRulesEngine.enable_rule("nonexistent")
    end
  end
end
