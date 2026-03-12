defmodule ApmV5Web.MetricsChannelTest do
  use ApmV5Web.ChannelCase

  setup do
    if Process.whereis(ApmV5.MetricsCollector), do: ApmV5.MetricsCollector.clear_all()

    {:ok, _, socket} =
      ApmV5Web.UserSocket
      |> socket(%{})
      |> subscribe_and_join(ApmV5Web.MetricsChannel, "metrics:live")

    %{socket: socket}
  end

  test "joining sends current fleet_metrics", %{socket: _socket} do
    assert_push "fleet_metrics", %{metrics: _metrics}
  end

  test "receives periodic fleet_metrics_updated", %{socket: _socket} do
    assert_push "fleet_metrics", _
    # The default interval is 5s, but we should get a push eventually
    assert_push "fleet_metrics_updated", %{metrics: _}, 6_000
  end

  test "set_interval changes push frequency", %{socket: socket} do
    assert_push "fleet_metrics", _

    ref = push(socket, "set_interval", %{"interval" => 1_000})
    assert_reply ref, :ok, %{interval: 1_000}

    # The old 5s timer will fire first, then subsequent pushes at 1s
    assert_push "fleet_metrics_updated", _, 6_000
  end

  test "set_interval clamps to valid range", %{socket: socket} do
    ref = push(socket, "set_interval", %{"interval" => 100})
    assert_reply ref, :ok, %{interval: 1_000}

    ref = push(socket, "set_interval", %{"interval" => 60_000})
    assert_reply ref, :ok, %{interval: 30_000}
  end

  test "set_interval rejects non-integer", %{socket: socket} do
    ref = push(socket, "set_interval", %{"interval" => "fast"})
    assert_reply ref, :error, %{reason: _}
  end
end
