defmodule ApmV4Web.HealthCheckLive do
  use ApmV4Web, :live_view
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(15_000, self(), :refresh)
    end
    {:ok, assign_data(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_event("run_checks", _params, socket) do
    ApmV4.HealthCheckRunner.run_now()
    Process.sleep(300)
    {:noreply, assign_data(socket)}
  end

  defp assign_data(socket) do
    checks = ApmV4.HealthCheckRunner.get_checks()
    overall = ApmV4.HealthCheckRunner.get_overall_health()
    assign(socket, checks: checks, overall: overall, page_title: "Health")
  end

  attr :active, :string, default: ""

  defp nav_item(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-colors",
        @active == "true" && "bg-primary text-primary-content font-medium" ||
          "text-base-content/70 hover:bg-base-200 hover:text-base-content"
      ]}
    >
      <.icon name={@icon} class="size-4 flex-shrink-0" />
      <span>{@label}</span>
    </a>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-100 overflow-hidden">
      <aside class="w-52 bg-base-200 border-r border-base-300 flex flex-col flex-shrink-0">
        <div class="p-3 border-b border-base-300">
          <a href="/" class="font-mono font-bold text-sm text-base-content">CCEM APM</a>
          <div class="text-xs text-base-content/40 mt-0.5">v4.0.0</div>
        </div>
        <nav class="flex-1 p-2 space-y-1 overflow-y-auto">
          <.nav_item icon="hero-squares-2x2" label="Dashboard" active="false" href="/" />
          <.nav_item icon="hero-globe-alt" label="All Projects" active="false" href="/apm-all" />
          <.nav_item icon="hero-rectangle-group" label="Formations" active="false" href="/formation" />
          <.nav_item icon="hero-clock" label="Timeline" active="false" href="/timeline" />
          <.nav_item icon="hero-bell" label="Notifications" active="false" href="/notifications" />
          <.nav_item icon="hero-queue-list" label="Background Tasks" active="false" href="/tasks" />
          <.nav_item icon="hero-magnifying-glass" label="Project Scanner" active="false" href="/scanner" />
          <.nav_item icon="hero-bolt" label="Actions" active="false" href="/actions" />
          <.nav_item icon="hero-sparkles" label="Skills" active="false" href="/skills" />
          <.nav_item icon="hero-arrow-path" label="Ralph" active="false" href="/ralph" />
          <.nav_item icon="hero-signal" label="Ports" active="false" href="/ports" />
          <.nav_item icon="hero-chart-bar" label="Analytics" active="false" href="/analytics" />
          <.nav_item icon="hero-heart" label="Health" active="true" href="/health" />
          <.nav_item icon="hero-chat-bubble-left-right" label="Conversations" active="false" href="/conversations" />
          <.nav_item icon="hero-puzzle-piece" label="Plugins" active="false" href="/plugins" />
          <.nav_item icon="hero-book-open" label="Docs" active="false" href="/docs" />
        </nav>
      </aside>

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
