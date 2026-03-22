defmodule ApmV5Web.HealthCheckLive do
  @moduledoc """
  LiveView for system health status at /health.

  Shows the latest health check results for all registered services,
  including APM server, CCEMHelper, and external integrations.
  """

  use ApmV5Web, :live_view

  import ApmV5Web.Components.GettingStartedWizard

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(15_000, self(), :refresh)
      # US-021: EventBus subscription for AG-UI health events
      ApmV5.AgUi.EventBus.subscribe("lifecycle:*")
    end
    {:ok, assign_data(socket)}
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
    <div class="flex h-screen bg-base-100 overflow-hidden">
      <.sidebar_nav current_path="/health" />

      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="bg-base-200 border-b border-base-300 px-4 py-2 flex items-center justify-between flex-shrink-0">
          <div class="flex items-center gap-3">
            <h1 class="font-semibold text-sm">Health Checks</h1>
            <span class={["badge badge-sm", overall_badge_class(@overall)]}>
              {@overall}
            </span>
          </div>
          <button phx-click="run_checks" class="btn btn-xs btn-ghost gap-1">
            <.icon name="hero-arrow-path" class="size-3.5" /> Run Checks
          </button>
        </header>

        <div class="flex-1 overflow-y-auto p-4">
          <div :if={@checks == []} class="text-center py-8 text-base-content/40 text-sm">
            Running health checks...
          </div>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
            <div :for={check <- @checks} class={["bg-base-200 rounded-lg p-4 border-l-4", check_border_class(check.status)]}>
              <div class="flex items-center justify-between mb-1">
                <span class="font-medium text-sm">{check.name}</span>
                <span class={["badge badge-xs", check_badge_class(check.status)]}>{check.status}</span>
              </div>
              <div class="text-xs text-base-content/60 font-mono">{check.message}</div>
            </div>
          </div>
        </div>
      </div>
    </div>
    <.wizard page="welcome" dom_id="ccem-wizard-welcome-health" />
    """
  end

  defp overall_badge_class(:healthy), do: "badge-success"
  defp overall_badge_class(:degraded), do: "badge-warning"
  defp overall_badge_class(:unhealthy), do: "badge-error"
  defp overall_badge_class(_), do: "badge-ghost"

  defp check_border_class(:ok), do: "border-success"
  defp check_border_class(:error), do: "border-error"
  defp check_border_class(_), do: "border-base-300"

  defp check_badge_class(:ok), do: "badge-success"
  defp check_badge_class(:error), do: "badge-error"
  defp check_badge_class(_), do: "badge-ghost"
end
