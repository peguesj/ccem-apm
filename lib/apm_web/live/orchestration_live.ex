defmodule ApmWeb.OrchestrationLive do
  @moduledoc """
  LiveView for the Orchestration dashboard.

  Displays active and historical orchestration runs with type badges,
  type filtering, and a D3.js DAG visualization panel.

  Subscribes to `"orchestration:runs"` PubSub for live run updates.
  """

  use ApmWeb, :live_view

  require Logger

  alias Apm.Orchestration.OrchestrationManager
  alias Apm.Orchestration.OrchestrationRunStore
  alias Apm.WorkflowRegistry

  @pubsub_topic "orchestration:runs"

  @type_badge_tones %{
    pipeline: "info",
    workflow: "accent",
    maintenance: "warning",
    sync: "neutral",
    formation: "iris",
    autonomous: "error"
  }

  # ── Mount ──────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Apm.PubSub, @pubsub_topic)
    end

    runs =
      try do
        OrchestrationManager.list_runs()
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    workflows =
      try do
        WorkflowRegistry.list_workflows()
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    {:ok,
     assign(socket,
       runs: runs,
       workflows: workflows,
       filter_type: nil,
       selected_run: nil,
       type_badge_tones: @type_badge_tones,
       page_title: "Orchestration",
       sidebar_collapsed: false,
       inspector_open: false
     )
     |> ApmWeb.Components.SidebarNav.assign_sidebar_nav_data()}
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

    {:noreply, assign(socket, selected_run: run, inspector_open: run != nil)}
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply, assign(socket, selected_run: nil, inspector_open: false)}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_collapsed: !socket.assigns.sidebar_collapsed)}
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
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar><.sidebar_nav current_path="/orchestration" /></:sidebar>
      <:topbar><.top_bar project_name="CCEM APM" /></:topbar>
      <:main>
        <div style="padding: var(--ccem-space-6); display: flex; flex-direction: column; gap: var(--ccem-space-4);">
          <%!-- Page header --%>
          <div style="display: flex; align-items: center; justify-content: space-between;">
            <div style="display: flex; align-items: center; gap: var(--ccem-space-3);">
              <h1 style="font-size: var(--ccem-text-lg); font-weight: 600; color: var(--ccem-fg-primary);">
                Orchestration
              </h1>
              <.badge tone="neutral">{length(@runs)} runs</.badge>
            </div>
            <div style="display: flex; align-items: center; gap: var(--ccem-space-2);">
              <.ds_input
                type="text"
                name="type_filter_display"
                value=""
                placeholder="Filter…"
                phx-change="noop"
              />
              <select
                phx-change="filter_type"
                name="type"
                style="background: var(--ccem-surface-2); color: var(--ccem-fg-primary); border: 1px solid var(--ccem-border); border-radius: var(--ccem-radius-sm); padding: 0 var(--ccem-space-2); height: 32px; font-size: var(--ccem-text-sm);"
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

          <%!-- Stats row --%>
          <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: var(--ccem-space-3);">
            <.stat_tile
              label="Total Runs"
              value={to_string(length(@runs))}
              delta_direction="flat"
            />
            <.stat_tile
              label="Active"
              value={to_string(Enum.count(@runs, &(&1.status == :running)))}
              delta_direction="flat"
            />
            <.stat_tile
              label="Completed"
              value={to_string(Enum.count(@runs, &(&1.status == :completed)))}
              delta_direction="flat"
            />
            <.stat_tile
              label="Workflows"
              value={to_string(length(@workflows))}
              delta_direction="flat"
            />
          </div>

          <%!-- Runs table --%>
          <.card padded={false}>
            <div style="padding: var(--ccem-space-3) var(--ccem-space-4); border-bottom: 1px solid var(--ccem-border); display: flex; align-items: center; justify-content: space-between;">
              <span style="font-size: var(--ccem-text-sm); font-weight: 600; color: var(--ccem-fg-primary);">
                Orchestration Runs
              </span>
              <span style="font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted);">
                Live — updates in real-time
              </span>
            </div>
            <.data_table id="orchestration-runs" rows={@runs}>
              <:col :let={run} label="ID">
                <span style="font-family: var(--ccem-font-mono); font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted);">
                  {String.slice(run.id, 0, 12)}…
                </span>
              </:col>
              <:col :let={run} label="Type">
                <.badge tone={Map.get(@type_badge_tones, run.orchestration_type, "neutral")}>
                  {run.orchestration_type}
                </.badge>
              </:col>
              <:col :let={run} label="Status">
                <.badge tone={run_status_tone(run.status)}>
                  {run.status}
                </.badge>
              </:col>
              <:col :let={run} label="Steps">
                <span style="font-size: var(--ccem-text-sm); color: var(--ccem-fg-secondary);">
                  {length(run.steps)}
                </span>
              </:col>
              <:col :let={run} label="Started">
                <span style="font-family: var(--ccem-font-mono); font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted);">
                  {Calendar.strftime(run.started_at, "%H:%M:%S")}
                </span>
              </:col>
              <:col :let={run} label="">
                <.btn variant="ghost" size="xs" phx-click="select_run" phx-value-id={run.id}>
                  View
                </.btn>
              </:col>
            </.data_table>
          </.card>
        </div>
      </:main>
      <:inspector>
        <%= if @selected_run do %>
          <div style="padding: var(--ccem-space-4); display: flex; flex-direction: column; gap: var(--ccem-space-4);">
            <div style="display: flex; align-items: center; justify-content: space-between;">
              <span style="font-size: var(--ccem-text-sm); font-weight: 600; color: var(--ccem-fg-primary);">
                Run Detail
              </span>
              <.btn variant="ghost" size="xs" phx-click="close_panel">
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </.btn>
            </div>

            <div style="display: flex; flex-direction: column; gap: var(--ccem-space-2);">
              <div style="font-family: var(--ccem-font-mono); font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted); word-break: break-all;">
                {@selected_run.id}
              </div>
              <div style="display: flex; align-items: center; gap: var(--ccem-space-2);">
                <span style="font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted);">
                  Type:
                </span>
                <.badge tone={Map.get(@type_badge_tones, @selected_run.orchestration_type, "neutral")}>
                  {@selected_run.orchestration_type}
                </.badge>
              </div>
              <div style="display: flex; align-items: center; gap: var(--ccem-space-2);">
                <span style="font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted);">
                  Status:
                </span>
                <.badge tone={run_status_tone(@selected_run.status)}>
                  {@selected_run.status}
                </.badge>
              </div>
              <div style="display: flex; align-items: center; gap: var(--ccem-space-2);">
                <span style="font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted);">
                  Steps:
                </span>
                <span style="font-size: var(--ccem-text-sm); color: var(--ccem-fg-secondary);">
                  {length(@selected_run.steps)}
                </span>
              </div>
            </div>
          </div>
        <% end %>
      </:inspector>
    </.page_layout>
    """
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  defp run_status_tone(:running), do: "accent"
  defp run_status_tone(:completed), do: "success"
  defp run_status_tone(:failed), do: "error"
  defp run_status_tone(:cancelled), do: "warning"
  defp run_status_tone(_), do: "neutral"
end
