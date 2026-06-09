defmodule ApmWeb.AnalyticsLive do
  @moduledoc """
  LiveView for agent analytics and telemetry charts at /analytics.

  Renders time-series token usage, task completion rates, and
  formation success metrics from AnalyticsStore.
  """

  use ApmWeb, :live_view

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(30_000, self(), :refresh)
      # US-021: EventBus subscriptions for AG-UI analytics events
      Apm.AgUi.EventBus.subscribe("lifecycle:*")
      Apm.AgUi.EventBus.subscribe("tool:*")
    end

    {:ok,
     socket
     |> assign(sidebar_collapsed: false, inspector_open: false)
     |> assign_data()
     |> ApmWeb.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    Apm.AnalyticsStore.refresh()
    Process.sleep(200)
    {:noreply, assign_data(socket)}
  end

  defp assign_data(socket) do
    summary = Apm.AnalyticsStore.get_summary()
    sessions = Apm.AnalyticsStore.get_sessions()

    assign(socket,
      summary: summary,
      sessions: Enum.take(sessions, 20),
      page_title: "Analytics"
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar><.sidebar_nav current_path="/analytics" /></:sidebar>
      <:topbar><.top_bar project_name="CCEM APM" /></:topbar>
      <:main>
        <%!-- Page header --%>
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
          <h1 style="margin: 0; font-size: 16px; font-weight: 600; color: var(--ccem-fg);">
            Analytics
          </h1>
          <.btn variant="ghost" size="xs" phx-click="refresh">Refresh</.btn>
        </div>

        <%!-- Summary stat tiles --%>
        <div style="display: flex; gap: 12px; margin-bottom: 16px; flex-wrap: wrap;">
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Total Sessions" value={to_string(@summary.total_sessions)} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Active Now" value={to_string(@summary.active_sessions)} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Total Tokens" value={format_number(@summary.total_tokens)} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Total Messages" value={to_string(@summary.total_messages)} />
          </.card>
        </div>

        <%!-- Model Distribution + Top Tools side-by-side --%>
        <div style="display: flex; gap: 12px; margin-bottom: 16px; flex-wrap: wrap;">
          <.card style="flex: 1; min-width: 200px; padding: 16px;">
            <div style="font-size: var(--ccem-t-sm, 13px); font-weight: 600; color: var(--ccem-fg); margin-bottom: 12px;">
              Model Distribution
            </div>
            <div
              :if={@summary.model_distribution == %{}}
              style="font-size: var(--ccem-t-sm, 13px); color: var(--ccem-fg-dim);"
            >
              No data yet
            </div>
            <div
              :for={{model, count} <- @summary.model_distribution}
              style="display: flex; align-items: center; gap: 8px; margin-bottom: 6px;"
            >
              <span style="font-size: var(--ccem-t-sm, 13px); font-family: monospace; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--ccem-fg);">
                {model}
              </span>
              <.badge tone="neutral">{to_string(count)}</.badge>
            </div>
          </.card>

          <.card style="flex: 1; min-width: 200px; padding: 16px;">
            <div style="font-size: var(--ccem-t-sm, 13px); font-weight: 600; color: var(--ccem-fg); margin-bottom: 12px;">
              Top Tools
            </div>
            <div
              :if={@summary.top_tools == %{}}
              style="font-size: var(--ccem-t-sm, 13px); color: var(--ccem-fg-dim);"
            >
              No data yet
            </div>
            <div
              :for={{tool, count} <- @summary.top_tools}
              style="display: flex; align-items: center; gap: 8px; margin-bottom: 6px;"
            >
              <span style="font-size: var(--ccem-t-sm, 13px); font-family: monospace; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--ccem-fg);">
                {tool}
              </span>
              <.badge tone="info">{to_string(count)}</.badge>
            </div>
          </.card>
        </div>

        <%!-- Recent Sessions table --%>
        <div style="margin-bottom: 4px; font-size: var(--ccem-t-sm, 13px); font-weight: 600; color: var(--ccem-fg);">
          Recent Sessions ({length(@sessions)})
        </div>
        <.card padded={false}>
          <div
            :if={@sessions == []}
            style="padding: 24px; text-align: center; font-size: var(--ccem-t-sm, 13px); color: var(--ccem-fg-dim);"
          >
            No sessions found in ~/.claude/projects/
          </div>
          <.data_table :if={@sessions != []} id="analytics-sessions-table" rows={@sessions}>
            <:col :let={row} label="Session">
              <span style="font-family: monospace; font-size: var(--ccem-t-sm, 13px);">
                {row.session_id}
              </span>
            </:col>
            <:col :let={row} label="Messages">
              {row.total_messages}
            </:col>
            <:col :let={row} label="Tokens">
              {format_number(row.total_tokens)}
            </:col>
            <:col :let={row} label="Last Modified">
              <span style="color: var(--ccem-fg-dim);">
                {format_mtime(row.last_modified)}
              </span>
            </:col>
          </.data_table>
        </.card>
      </:main>
    </.page_layout>
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
