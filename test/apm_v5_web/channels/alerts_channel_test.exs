defmodule ApmV5Web.AlertsChannelTest do
  use ApmV5Web.ChannelCase

  alias ApmV5.AlertRulesEngine

  setup do
    ApmV5.GenServerHelpers.ensure_processes_alive()
    # Reinitialize alert rules engine to clear history
    if Process.whereis(AlertRulesEngine) do
      GenServer.call(AlertRulesEngine, :reinit)
    end

    {:ok, _, socket} =
      ApmV5Web.UserSocket
      |> socket(%{})
      |> subscribe_and_join(ApmV5Web.AlertsChannel, "alerts:feed")

    %{socket: socket}
  end

  test "joining sends alert_history", %{socket: _socket} do
    assert_push "alert_history", %{alerts: alerts}
    assert is_list(alerts)
  end

  test "receives alert_fired when alert triggers", %{socket: _socket} do
    assert_push "alert_history", _

    # Fire an alert by evaluating a metric that breaches a rule
    # The bootstrap "fleet_error_rate" rule: metric "error_rate", scope :fleet, threshold 0.10, consecutive 2
    AlertRulesEngine.evaluate("error_rate", :fleet, 0.5)
    AlertRulesEngine.evaluate("error_rate", :fleet, 0.5)

    assert_push "alert_fired", %{alert: alert}
    assert alert.rule_id == "fleet_error_rate"
  end

  test "acknowledge replies ok for existing alert", %{socket: socket} do
    assert_push "alert_history", _

    # Create an alert
    AlertRulesEngine.evaluate("error_rate", :fleet, 0.5)
    AlertRulesEngine.evaluate("error_rate", :fleet, 0.5)
    assert_push "alert_fired", %{alert: alert}

    ref = push(socket, "acknowledge", %{"alert_id" => alert.id})
    assert_reply ref, :ok, %{acknowledged: _}
  end

  test "acknowledge replies error for non-existent alert", %{socket: socket} do
    assert_push "alert_history", _

    ref = push(socket, "acknowledge", %{"alert_id" => "nonexistent"})
    assert_reply ref, :error, %{reason: _}
  end
end
