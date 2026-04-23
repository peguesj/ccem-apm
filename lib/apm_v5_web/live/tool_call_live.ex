defmodule ApmV5Web.ToolCallLive do
  @moduledoc """
  Real-time tool call activity dashboard.

  ## US-038 Acceptance Criteria (DoD):
  - Mounted at /tool-calls
  - Active tool calls panel with agent, tool, elapsed, status
  - Tool usage statistics table
  - Real-time updates via EventBus 'tool:*'
  - Filter by agent and time range
  - Nav item in sidebar
  - mix compile --warnings-as-errors passes
  """

  use ApmV5Web, :live_view

  import ApmV5Web.Components.GettingStartedWizard

  alias ApmV5.AgUi.ToolCallTracker
  alias ApmV5.AgUi.EventBus

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      EventBus.subscribe("tool:*")
    end

    active = ToolCallTracker.list_active()
    stats = ToolCallTracker.stats()

    {:ok,
     socket
     |> assign(:page_title, "Tool Calls")
     |> assign(:active_calls, active)
     |> assign(:stats, stats)
     |> assign(:agent_filter, nil
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data())}
  end

  @impl true
  def handle_info({:event_bus, _topic, _event}, socket) do
    active = ToolCallTracker.list_active()
    stats = ToolCallTracker.stats()

    {:noreply,
     socket
     |> assign(:active_calls, active)
     |> assign(:stats, stats)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter_agent", %{"agent" => agent}, socket) do
    filter = if agent == "", do: nil, else: agent
    {:noreply, assign(socket, :agent_filter, filter)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <.sidebar_nav current_path="/tool-calls" />

      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0 relative z-10">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Tool Calls</h2>
            <div class="stats stats-sm shadow bg-base-300">
              <div class="stat py-1 px-3">
                <div class="stat-title text-xs">Active</div>
                <div class="stat-value text-primary text-sm"><%= @stats.active %></div>
              </div>
              <div class="stat py-1 px-3">
                <div class="stat-title text-xs">Total</div>
                <div class="stat-value text-sm"><%= @stats.total %></div>
              </div>
              <div class="stat py-1 px-3">
                <div class="stat-title text-xs">Avg</div>
                <div class="stat-value text-sm"><%= @stats.avg_duration_ms %>ms</div>
              </div>
            </div>
          </div>
        </header>

        <div class="flex-1 overflow-y-auto p-6 space-y-6">
          <div class="card bg-base-200 shadow-xl">
            <div class="card-body">
              <h2 class="card-title">Active Tool Calls</h2>
              <div class="overflow-x-auto">
                <table class="table table-zebra">
                  <thead>
                    <tr>
                      <th>Agent</th>
                      <th>Tool</th>
                      <th>Status</th>
                      <th>Started</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for call <- filtered_calls(@active_calls, @agent_filter) do %>
                      <tr>
                        <td class="font-mono text-sm"><%= call.agent_id %></td>
                        <td><span class="badge badge-info"><%= call.tool_name %></span></td>
                        <td>
                          <span class={status_badge(call.status)}><%= call.status %></span>
                        </td>
                        <td class="text-xs opacity-70"><%= call.started_at_wall %></td>
                      </tr>
                    <% end %>
                    <%= if Enum.empty?(@active_calls) do %>
                      <tr><td colspan="4" class="text-center opacity-50">No active tool calls</td></tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          </div>

          <div class="card bg-base-200 shadow-xl">
            <div class="card-body">
              <h2 class="card-title">Top Tools</h2>
              <div class="overflow-x-auto">
                <table class="table table-zebra">
                  <thead>
                    <tr><th>Tool</th><th>Calls</th></tr>
                  </thead>
                  <tbody>
                    <%= for {tool, count} <- @stats.top_tools do %>
                      <tr>
                        <td class="font-mono"><%= tool %></td>
                        <td><%= count %></td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    <.wizard page="ag-ui" dom_id="ccem-wizard-ag-ui-toolcall" />
    """
  end

  defp filtered_calls(calls, nil), do: calls
  defp filtered_calls(calls, agent_id) do
    Enum.filter(calls, & &1.agent_id == agent_id)
  end

  defp status_badge(:in_progress), do: "badge badge-warning"
  defp status_badge(:completed), do: "badge badge-success"
  defp status_badge(_), do: "badge"
end
