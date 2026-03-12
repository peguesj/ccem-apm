defmodule ApmV5Web.AlertsChannel do
  use ApmV5Web, :channel

  alias ApmV5.AlertRulesEngine

  @impl true
  def join("alerts:feed", _params, socket) do
    send(self(), :after_join)
    {:ok, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:alerts")
    Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:slo")

    recent = AlertRulesEngine.get_alert_history(limit: 20)
    push(socket, "alert_history", %{alerts: recent})
    {:noreply, socket}
  end

  def handle_info({:alert_fired, alert}, socket) do
    push(socket, "alert_fired", %{alert: alert})
    {:noreply, socket}
  end

  def handle_info({:slo_transition, data}, socket) do
    push(socket, "slo_transition", %{data: data})
    {:noreply, socket}
  end

  @impl true
  def handle_in("acknowledge", %{"alert_id" => alert_id}, socket) do
    case AlertRulesEngine.acknowledge(alert_id) do
      :ok -> {:reply, {:ok, %{acknowledged: alert_id}}, socket}
      {:error, :not_found} -> {:reply, {:error, %{reason: "alert not found"}}, socket}
    end
  end
end
