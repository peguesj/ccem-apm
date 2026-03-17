defmodule ApmV5Web.MetricsChannel do
  @moduledoc """
  Phoenix Channel for real-time metrics streaming.

  Handles connections on the `metrics:live` topic. Broadcasts live
  telemetry and performance metrics to connected clients.
  """

  use ApmV5Web, :channel

  alias ApmV5.MetricsCollector

  @default_interval 5_000
  @min_interval 1_000
  @max_interval 30_000

  @impl true
  def join("metrics:live", _params, socket) do
    send(self(), :after_join)
    socket = assign(socket, :interval, @default_interval)
    {:ok, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:metrics")
    metrics = MetricsCollector.get_fleet_metrics()
    push(socket, "fleet_metrics", %{metrics: metrics})
    schedule_push(socket.assigns.interval)
    {:noreply, socket}
  end

  def handle_info(:push_metrics, socket) do
    metrics = MetricsCollector.get_fleet_metrics()
    push(socket, "fleet_metrics_updated", %{metrics: metrics})
    schedule_push(socket.assigns.interval)
    {:noreply, socket}
  end

  def handle_info({:fleet_metrics_updated, _metrics}, socket) do
    # We use our own interval-based push, so just ignore PubSub pushes
    {:noreply, socket}
  end

  @impl true
  def handle_in("set_interval", %{"interval" => interval}, socket) when is_integer(interval) do
    clamped = interval |> max(@min_interval) |> min(@max_interval)
    {:reply, {:ok, %{interval: clamped}}, assign(socket, :interval, clamped)}
  end

  def handle_in("set_interval", _params, socket) do
    {:reply, {:error, %{reason: "interval must be an integer in ms"}}, socket}
  end

  defp schedule_push(interval) do
    Process.send_after(self(), :push_metrics, interval)
  end
end
