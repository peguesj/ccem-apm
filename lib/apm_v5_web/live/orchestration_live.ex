defmodule ApmV5Web.OrchestrationLive do
  @moduledoc """
  LiveView for the Orchestration dashboard.

  Displays active and historical orchestration runs with type badges,
  type filtering, and a D3.js DAG visualization panel.

  Subscribes to `"orchestration:runs"` PubSub for live run updates.
  """

  use ApmV5Web, :live_view

  require Logger

  alias ApmV5.Orchestration.OrchestrationManager
  alias ApmV5.Orchestration.OrchestrationRunStore
  alias ApmV5.WorkflowRegistry

  @pubsub_topic "orchestration:runs"

  @type_badge_colors %{
    pipeline: "badge-info",
    workflow: "badge-primary",
    maintenance: "badge-warning",
    sync: "badge-secondary",
    formation: "badge-accent",
    autonomous: "badge-error"
  }

  # ── Mount ──────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic)
    end

    runs = OrchestrationManager.list_runs()
    workflows = WorkflowRegistry.list_workflows()

    {:ok,
     assign(socket,
       runs: runs,
       workflows: workflows,
       filter_type: nil,
       selected_run: nil,
       type_badge_colors: @type_badge_colors,
       page_title: "Orchestration"
     )
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("filter_type", %{"type" => ""}, socket) do
    {:noreply, assign(socket, filter_type: nil, runs: OrchestrationManager.list_runs())}
  end

  def handle_event("filter_type", %{"type" => type}, socket) do
    atom_type = String.to_existing_atom(type)
    runs = OrchestrationRunStore.list_by_type(atom_type)
    {:noreply, assign(socket, filter_type: atom_type, runs: runs)}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("select_run", %{"id" => id}, socket) do
    run =
      case OrchestrationManager.get_run(id) do
        {:ok, r} -> r
        _ -> nil
      end

    {:noreply, assign(socket, selected_run: run)}
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply, assign(socket, selected_run: nil)}
  end

  # ── PubSub ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_info({event, run}, socket)
      when event in [:run_started, :run_advanced, :run_cancelled] do
    runs =
      case socket.assigns.filter_type do
        nil -> OrchestrationManager.list_runs()
        t -> OrchestrationRunStore.list_by_type(t)
      end

    # Update selected_run if it was affected
    selected =
      case socket.assigns.selected_run do
        %{id: id} when id == run.id -> run
        other -> other
      end

    {:noreply, assign(socket, runs: runs, selected_run: selected)}
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 space-y-4">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">Orchestration</h1>
        <div class="flex gap-2">
          <select
            phx-change="filter_type"
            name="type"
            class="select select-sm select-bordered"
          >
            <option value="">All types</option>
            <option value="pipeline">Pipeline</option>
            <option value="workflow">Workflow</option>
            <option value="maintenance">Maintenance</option>
            <option value="sync">Sync</option>
            <option value="formation">Formation</option>
            <option value="autonomous">Autonomous</option>
          </select>
        </div>
      </div>

      <div class="overflow-x-auto">
        <table class="table table-sm w-full">
          <thead>
            <tr>
              <th>ID</th>
              <th>Type</th>
              <th>Status</th>
              <th>Steps</th>
              <th>Started</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <%= for run <- @runs do %>
              <tr class="hover cursor-pointer" phx-click="select_run" phx-value-id={run.id}>
                <td class="font-mono text-xs"><%= run.id %></td>
                <td>
                  <span class={"badge badge-sm #{Map.get(@type_badge_colors, run.orchestration_type, "badge-ghost")}"}>
                    <%= run.orchestration_type %>
                  </span>
                </td>
                <td><span class="badge badge-sm badge-ghost"><%= run.status %></span></td>
                <td><%= length(run.steps) %></td>
                <td class="text-xs"><%= Calendar.strftime(run.started_at, "%H:%M:%S") %></td>
                <td>
                  <button class="btn btn-xs btn-ghost" phx-click="select_run" phx-value-id={run.id}>
                    View
                  </button>
                </td>
              </tr>
            <% end %>
            <%= if Enum.empty?(@runs) do %>
              <tr><td colspan="6" class="text-center text-base-content/50 py-8">No runs</td></tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <%= if @selected_run do %>
        <div class="fixed inset-0 bg-black/50 z-50 flex items-end justify-center" phx-click="close_panel">
          <div class="bg-base-100 rounded-t-2xl w-full max-w-2xl p-6 space-y-4" phx-click-stop>
            <div class="flex justify-between items-center">
              <h2 class="font-bold text-lg">Run <span class="font-mono text-sm"><%= @selected_run.id %></span></h2>
              <button phx-click="close_panel" class="btn btn-sm btn-ghost btn-circle">
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>
            <div class="grid grid-cols-2 gap-2 text-sm">
              <div><span class="font-semibold">Type:</span>
                <span class={"badge badge-sm ml-1 #{Map.get(@type_badge_colors, @selected_run.orchestration_type, "badge-ghost")}"}>
                  <%= @selected_run.orchestration_type %>
                </span>
              </div>
              <div><span class="font-semibold">Status:</span> <%= @selected_run.status %></div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
