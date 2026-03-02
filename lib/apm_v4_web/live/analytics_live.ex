defmodule ApmV4Web.AnalyticsLive do
  use ApmV4Web, :live_view
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(30_000, self(), :refresh)
    end
    {:ok, assign_data(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    ApmV4.AnalyticsStore.refresh()
    Process.sleep(200)
    {:noreply, assign_data(socket)}
  end

  defp assign_data(socket) do
    summary = ApmV4.AnalyticsStore.get_summary()
    sessions = ApmV4.AnalyticsStore.get_sessions()
    assign(socket,
      summary: summary,
      sessions: Enum.take(sessions, 20),
      page_title: "Analytics"
    )
  end

  attr :active, :string, default: "false"
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, required: true

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
      <span :if={assigns[:badge]} class="ml-auto badge badge-xs">{@badge}</span>
    </a>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-100 overflow-hidden">
      <%!-- Sidebar --%>
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
          <.nav_item icon="hero-chart-bar" label="Analytics" active="true" href="/analytics" />
          <.nav_item icon="hero-heart" label="Health" active="false" href="/health" />
          <.nav_item icon="hero-chat-bubble-left-right" label="Conversations" active="false" href="/conversations" />
          <.nav_item icon="hero-puzzle-piece" label="Plugins" active="false" href="/plugins" />
          <.nav_item icon="hero-book-open" label="Docs" active="false" href="/docs" />
        </nav>
      </aside>

      <%!-- Main --%>
      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="bg-base-200 border-b border-base-300 px-4 py-2 flex items-center justify-between flex-shrink-0">
          <h1 class="font-semibold text-sm">Analytics</h1>
          <button phx-click="refresh" class="btn btn-xs btn-ghost gap-1">
            <.icon name="hero-arrow-path" class="size-3.5" /> Refresh
          </button>
        </header>

        <div class="flex-1 overflow-y-auto p-4 space-y-4">
          <%!-- Summary Cards --%>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
            <div class="stat bg-base-200 rounded-lg p-3">
              <div class="stat-title text-xs">Total Sessions</div>
              <div class="stat-value text-2xl">{@summary.total_sessions}</div>
            </div>
            <div class="stat bg-base-200 rounded-lg p-3">
              <div class="stat-title text-xs">Active Now</div>
              <div class="stat-value text-2xl text-success">{@summary.active_sessions}</div>
            </div>
            <div class="stat bg-base-200 rounded-lg p-3">
              <div class="stat-title text-xs">Total Tokens</div>
              <div class="stat-value text-xl">{format_number(@summary.total_tokens)}</div>
            </div>
            <div class="stat bg-base-200 rounded-lg p-3">
              <div class="stat-title text-xs">Total Messages</div>
              <div class="stat-value text-2xl">{@summary.total_messages}</div>
            </div>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <%!-- Model Distribution --%>
            <div class="bg-base-200 rounded-lg p-4">
              <h2 class="text-sm font-semibold mb-3">Model Distribution</h2>
              <div :if={@summary.model_distribution == %{}} class="text-xs text-base-content/40">No data yet</div>
              <div :for={{model, count} <- @summary.model_distribution} class="flex items-center gap-2 mb-1.5">
                <div class="text-xs font-mono flex-1 truncate">{model}</div>
                <div class="text-xs text-base-content/60">{count}</div>
              </div>
            </div>

            <%!-- Top Tools --%>
            <div class="bg-base-200 rounded-lg p-4">
              <h2 class="text-sm font-semibold mb-3">Top Tools</h2>
              <div :if={@summary.top_tools == %{}} class="text-xs text-base-content/40">No data yet</div>
              <div :for={{tool, count} <- @summary.top_tools} class="flex items-center gap-2 mb-1.5">
                <div class="text-xs font-mono flex-1 truncate">{tool}</div>
                <div class="text-xs text-base-content/60">{count}</div>
              </div>
            </div>
          </div>

          <%!-- Recent Sessions --%>
          <div class="bg-base-200 rounded-lg p-4">
            <h2 class="text-sm font-semibold mb-3">Recent Sessions ({length(@sessions)})</h2>
            <div :if={@sessions == []} class="text-xs text-base-content/40">No sessions found in ~/.claude/projects/</div>
            <div class="overflow-x-auto">
              <table class="table table-xs w-full">
                <thead>
                  <tr>
                    <th>Session</th>
                    <th>Messages</th>
                    <th>Tokens</th>
                    <th>Last Modified</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={session <- @sessions}>
                    <td class="font-mono text-xs max-w-xs truncate">{session.session_id}</td>
                    <td>{session.total_messages}</td>
                    <td>{format_number(session.total_tokens)}</td>
                    <td class="text-base-content/50">{format_mtime(session.last_modified)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n), do: to_string(n)

  defp format_mtime(nil), do: "?"
  defp format_mtime({date, time}) do
    case NaiveDateTime.from_erl({date, time}) do
      {:ok, dt} -> Calendar.strftime(dt, "%m/%d %H:%M")
      _ -> "?"
    end
  end
  defp format_mtime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%m/%d %H:%M")
  defp format_mtime(_), do: "?"
end
