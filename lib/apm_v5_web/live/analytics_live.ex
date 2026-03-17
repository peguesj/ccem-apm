defmodule ApmV5Web.AnalyticsLive do
  use ApmV5Web, :live_view

  import ApmV5Web.Components.GettingStartedWizard

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(30_000, self(), :refresh)
      # US-021: EventBus subscriptions for AG-UI analytics events
      ApmV5.AgUi.EventBus.subscribe("lifecycle:*")
      ApmV5.AgUi.EventBus.subscribe("tool:*")
    end
    {:ok, assign_data(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    ApmV5.AnalyticsStore.refresh()
    Process.sleep(200)
    {:noreply, assign_data(socket)}
  end

  defp assign_data(socket) do
    summary = ApmV5.AnalyticsStore.get_summary()
    sessions = ApmV5.AnalyticsStore.get_sessions()
    assign(socket,
      summary: summary,
      sessions: Enum.take(sessions, 20),
      page_title: "Analytics"
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-100 overflow-hidden">
      <%!-- Sidebar --%>
      <.sidebar_nav current_path="/analytics" />

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
    <.wizard page="agents" dom_id="ccem-wizard-agents-analytics" />
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
