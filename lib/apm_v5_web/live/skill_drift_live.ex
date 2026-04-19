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
     |> assign(:fix_result, nil)}
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
    <div class="p-6 space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold text-white">Skill Drift Detector</h1>
        <div class="flex gap-2">
          <button phx-click="rescan" class="btn btn-sm btn-outline btn-info">
            Rescan
          </button>
          <button phx-click="fix_all" class="btn btn-sm btn-primary" disabled={@fixing}>
            <%= if @fixing, do: "Fixing...", else: "Fix All" %>
          </button>
        </div>
      </div>

      <%!-- Summary cards --%>
      <div class="grid grid-cols-4 gap-4">
        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-title">Scanned</div>
          <div class="stat-value text-info"><%= @report.summary.scanned %></div>
        </div>
        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-title">Clean</div>
          <div class="stat-value text-success"><%= @report.summary.clean %></div>
        </div>
        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-title">Warning</div>
          <div class="stat-value text-warning"><%= @report.summary.warning %></div>
        </div>
        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-title">Critical</div>
          <div class="stat-value text-error"><%= @report.summary.critical %></div>
        </div>
      </div>

      <%!-- Fix result banner --%>
      <%= if @fix_result do %>
        <div class="alert alert-success">
          <span>Applied <%= @fix_result.fixes_applied %> of <%= @fix_result.fixes_available %> available fixes.</span>
        </div>
      <% end %>

      <%!-- Findings table --%>
      <div class="overflow-x-auto">
        <table class="table table-zebra w-full">
          <thead>
            <tr>
              <th>Severity</th>
              <th>Skill</th>
              <th>Type</th>
              <th>Line</th>
              <th>Found</th>
              <th>Expected</th>
              <th>Fixable</th>
            </tr>
          </thead>
          <tbody>
            <%= for {severity, findings} <- [
              {:critical, Map.get(@report.findings_by_severity, :critical, [])},
              {:warning, Map.get(@report.findings_by_severity, :warning, [])},
              {:info, Map.get(@report.findings_by_severity, :info, [])}
            ], finding <- findings do %>
              <tr>
                <td>
                  <span class={severity_badge_class(severity)}>
                    <%= severity %>
                  </span>
                </td>
                <td class="font-mono text-sm"><%= finding.skill_name %></td>
                <td><%= finding.drift_type %></td>
                <td><%= finding.line %></td>
                <td class="font-mono text-sm text-error"><%= finding.found %></td>
                <td class="font-mono text-sm text-success"><%= finding.expected %></td>
                <td>
                  <%= if finding.fixable do %>
                    <span class="badge badge-success badge-sm">Yes</span>
                  <% else %>
                    <span class="badge badge-ghost badge-sm">No</span>
                  <% end %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <%= if all_findings_empty?(@report) do %>
        <div class="text-center text-success py-8">
          All skills are clean. No drift detected.
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp severity_badge_class(:critical), do: "badge badge-error badge-sm"
  defp severity_badge_class(:warning), do: "badge badge-warning badge-sm"
  defp severity_badge_class(:info), do: "badge badge-info badge-sm"
  defp severity_badge_class(_), do: "badge badge-ghost badge-sm"

  defp all_findings_empty?(report) do
    report.summary.critical == 0 and report.summary.warning == 0 and
      report.summary.info == 0
  end
end
