defmodule ApmV5Web.HealthCheckLive do
  @moduledoc """
  LiveView for system health status at /health.

  Shows the latest health check results for all registered services,
  including APM server, CCEMHelper, and external integrations.
  """

  use ApmV5Web, :live_view

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(15_000, self(), :refresh)
      # US-021: EventBus subscription for AG-UI health events
      ApmV5.AgUi.EventBus.subscribe("lifecycle:*")
    end
    {:ok,
     socket
     |> assign(sidebar_collapsed: false, inspector_open: false)
     |> assign_data()
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign_data(socket)}
  end

  def handle_info(:post_check_refresh, socket), do: {:noreply, assign_data(socket)}

  @impl true
  def handle_event("run_checks", _params, socket) do
    ApmV5.HealthCheckRunner.run_now()
    Process.send_after(self(), :post_check_refresh, 300)
    {:noreply, socket}
  end

  defp assign_data(socket) do
    checks = ApmV5.HealthCheckRunner.get_checks()
    overall = ApmV5.HealthCheckRunner.get_overall_health()
    assign(socket, checks: checks, overall: overall, page_title: "Health")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar><.sidebar_nav current_path="/health" /></:sidebar>
      <:topbar><.top_bar project_name="CCEM APM" /></:topbar>
      <:main>
        <%!-- Page header --%>
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
          <div style="display: flex; align-items: center; gap: 10px;">
            <h1 style="margin: 0; font-size: 16px; font-weight: 600; color: var(--ccem-fg);">Health Checks</h1>
            <.badge tone={overall_health_tone(@overall)}>{to_string(@overall)}</.badge>
          </div>
          <.btn variant="ghost" size="xs" phx-click="run_checks">Run Checks</.btn>
        </div>

        <%!-- Empty state --%>
        <div :if={@checks == []}
             style="text-align: center; padding: 32px; font-size: var(--ccem-t-sm, 13px); color: var(--ccem-fg-dim);">
          Running health checks...
        </div>

        <%!-- Checks table --%>
        <.card :if={@checks != []} padded={false}>
          <.data_table id="health-checks-table" rows={@checks}>
            <:col :let={row} label="Service">
              <span style="font-size: var(--ccem-t-sm, 13px); font-weight: 500; color: var(--ccem-fg);">
                {row.name}
              </span>
            </:col>
            <:col :let={row} label="Status">
              <.badge tone={check_tone(row.status)}>{to_string(row.status)}</.badge>
            </:col>
            <:col :let={row} label="Message">
              <span style="font-family: monospace; font-size: var(--ccem-t-sm, 13px); color: var(--ccem-fg-dim);">
                {row.message}
              </span>
            </:col>
          </.data_table>
        </.card>
      </:main>
    </.page_layout>
    """
  end

  defp overall_health_tone("healthy"), do: "success"
  defp overall_health_tone(:healthy), do: "success"
  defp overall_health_tone("degraded"), do: "warning"
  defp overall_health_tone(:degraded), do: "warning"
  defp overall_health_tone("critical"), do: "error"
  defp overall_health_tone(:critical), do: "error"
  defp overall_health_tone("unhealthy"), do: "error"
  defp overall_health_tone(:unhealthy), do: "error"
  defp overall_health_tone(_), do: "neutral"

  defp check_tone(:ok), do: "success"
  defp check_tone("ok"), do: "success"
  defp check_tone(:error), do: "error"
  defp check_tone("error"), do: "error"
  defp check_tone(:warning), do: "warning"
  defp check_tone("warning"), do: "warning"
  defp check_tone(_), do: "neutral"
end
