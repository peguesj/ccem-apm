defmodule ApmV5Web.SkillDriftLive do
  @moduledoc """
  LiveView for the Skill Drift Detector — shows scan results with severity
  badges and one-click fix for auto-correctable drift.

  Part of US-385.
  """

  use ApmV5Web, :live_view

  alias ApmV5.Plugins.SkillDrift.SkillDriftPlugin

  @impl true
  def mount(_params, _session, socket) do
    report = SkillDriftPlugin.run_report()

    {:ok,
     socket
     |> assign(:page_title, "Skill Drift Detector")
     |> assign(:report, report)
     |> assign(:fixing, false)
     |> assign(:fix_result, nil)
     |> assign(:sidebar_collapsed, false)
     |> assign(:inspector_open, false)
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  @impl true
  def handle_event("rescan", _params, socket) do
    report = SkillDriftPlugin.run_report()
    {:noreply, assign(socket, report: report, fix_result: nil)}
  end

  @impl true
  def handle_event("fix_all", _params, socket) do
    socket = assign(socket, :fixing, true)
    {:ok, fix_result} = SkillDriftPlugin.handle_action("skill_drift_fix", %{}, [])
    report = SkillDriftPlugin.run_report()

    {:noreply,
     socket
     |> assign(:report, report)
     |> assign(:fixing, false)
     |> assign(:fix_result, fix_result)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar><.sidebar_nav current_path="/skills" /></:sidebar>
      <:topbar><.top_bar project_name="CCEM APM" /></:topbar>
      <:main>
        <%!-- Page header --%>
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 20px;">
          <h1 style="margin: 0; font-size: 16px; font-weight: 600; color: var(--ccem-fg);">Skill Drift Detector</h1>
          <div style="display: flex; gap: 8px;">
            <.btn variant="secondary" size="sm" phx-click="rescan">Rescan</.btn>
            <.btn variant="primary" size="sm" phx-click="fix_all" disabled={@fixing}>
              <%= if @fixing, do: "Fixing...", else: "Fix All" %>
            </.btn>
          </div>
        </div>

        <%!-- Summary stat tiles --%>
        <div style="display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 20px;">
          <.card padded={true} style="flex: 1; min-width: 120px;">
            <.stat_tile label="Scanned" value={to_string(@report.summary.scanned)} />
          </.card>
          <.card padded={true} style="flex: 1; min-width: 120px;">
            <.stat_tile label="Clean" value={to_string(@report.summary.clean)} />
          </.card>
          <.card padded={true} style="flex: 1; min-width: 120px;">
            <.stat_tile label="Warning" value={to_string(@report.summary.warning)} />
          </.card>
          <.card padded={true} style="flex: 1; min-width: 120px;">
            <.stat_tile label="Critical" value={to_string(@report.summary.critical)} />
          </.card>
        </div>

        <%!-- Fix result banner --%>
        <%= if @fix_result do %>
          <div style="margin-bottom: 16px; padding: 10px 14px; border-radius: 6px; background: color-mix(in srgb, var(--ccem-ok) 12%, transparent); border: 1px solid color-mix(in srgb, var(--ccem-ok) 30%, transparent); color: var(--ccem-ok); font-size: 13px;">
            Applied <%= @fix_result.fixes_applied %> of <%= @fix_result.fixes_available %> available fixes.
          </div>
        <% end %>

        <%!-- Findings table --%>
        <.card padded={false}>
          <.data_table id="drift-findings-table" rows={
            for {severity, findings} <- [
              {:critical, Map.get(@report.findings_by_severity, :critical, [])},
              {:warning, Map.get(@report.findings_by_severity, :warning, [])},
              {:info, Map.get(@report.findings_by_severity, :info, [])}
            ], finding <- findings do
              Map.put(finding, :severity, severity)
            end
          }>
            <:col :let={row} label="Severity">
              <.badge tone={severity_tone(row.severity)}>
                <%= row.severity %>
              </.badge>
            </:col>
            <:col :let={row} label="Skill">
              <span style="font-family: monospace; font-size: 12px;"><%= row.skill_name %></span>
            </:col>
            <:col :let={row} label="Type"><%= row.drift_type %></:col>
            <:col :let={row} label="Line"><%= row.line %></:col>
            <:col :let={row} label="Found">
              <span style="font-family: monospace; font-size: 12px; color: var(--ccem-err);"><%= row.found %></span>
            </:col>
            <:col :let={row} label="Expected">
              <span style="font-family: monospace; font-size: 12px; color: var(--ccem-ok);"><%= row.expected %></span>
            </:col>
            <:col :let={row} label="Fixable">
              <%= if row.fixable do %>
                <.badge tone="success">Yes</.badge>
              <% else %>
                <.badge tone="neutral">No</.badge>
              <% end %>
            </:col>
          </.data_table>
        </.card>

        <%!-- Empty state --%>
        <%= if all_findings_empty?(@report) do %>
          <div style="text-align: center; padding: 48px 0; color: var(--ccem-ok); font-size: 14px;">
            All skills are clean. No drift detected.
          </div>
        <% end %>
      </:main>
    </.page_layout>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp severity_tone(:critical), do: "error"
  defp severity_tone(:warning), do: "warning"
  defp severity_tone(:info), do: "info"
  defp severity_tone(_), do: "neutral"

  defp all_findings_empty?(report) do
    report.summary.critical == 0 and report.summary.warning == 0 and
      report.summary.info == 0
  end
end
