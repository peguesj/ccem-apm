defmodule ApmV5Web.TasksLive do
  @moduledoc """
  LiveView for background task monitoring at /tasks.

  Shows running, queued, and completed background tasks with
  log streaming, stop controls, and elapsed runtime.
  """

  use ApmV5Web, :live_view


  alias ApmV5.BackgroundTasksStore

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
      # US-021: EventBus subscription for AG-UI activity events
      ApmV5.AgUi.EventBus.subscribe("activity:*")
    end

    {:ok,
     socket
     |> assign(:page_title, "Background Tasks")
     |> assign(:filter, "all")
     |> assign(:selected_task_id, nil)
     |> assign(:sidebar_collapsed, false)
     |> assign(:inspector_open, false)
     |> load_tasks()
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, load_tasks(socket)}
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply, socket |> assign(:filter, status) |> load_tasks()}
  end

  def handle_event("view_logs", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_task_id, id)}
  end

  def handle_event("close_logs", _params, socket) do
    {:noreply, assign(socket, :selected_task_id, nil)}
  end

  def handle_event("stop_task", %{"id" => id}, socket) do
    try do BackgroundTasksStore.stop_task(id) catch :exit, _ -> :ok end
    {:noreply, load_tasks(socket)}
  end

  def handle_event("delete_task", %{"id" => id}, socket) do
    try do BackgroundTasksStore.delete_task(id) catch :exit, _ -> :ok end
    {:noreply, load_tasks(socket)}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_collapsed: !socket.assigns.sidebar_collapsed)}
  end

  def handle_event("toggle_inspector", _params, socket) do
    {:noreply, assign(socket, inspector_open: !socket.assigns.inspector_open)}
  end

  defp load_tasks(socket) do
    filter = socket.assigns[:filter] || "all"

    filter_map = if filter == "all", do: %{}, else: %{status: filter}
    tasks =
      try do
        BackgroundTasksStore.list_tasks(filter_map)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    assign(socket, :tasks, tasks)
  end

  defp selected_task(assigns) do
    case assigns[:selected_task_id] do
      nil -> nil
      id ->
        try do
          case BackgroundTasksStore.get_task(id) do
            {:ok, task} -> task
            _ -> nil
          end
        rescue _ -> nil
        catch :exit, _ -> nil
        end
    end
  end

  # --- Helpers ---

  defp status_tone("running"), do: "info"
  defp status_tone("completed"), do: "ok"
  defp status_tone("failed"), do: "err"
  defp status_tone("stopped"), do: "neutral"
  defp status_tone(_), do: "neutral"

  defp format_runtime(seconds) when is_integer(seconds) and seconds >= 60 do
    m = div(seconds, 60)
    s = rem(seconds, 60)
    "#{m}m #{s}s"
  end
  defp format_runtime(seconds) when is_integer(seconds), do: "#{seconds}s"
  defp format_runtime(_), do: "-"

  defp count_by_status(tasks, status), do: Enum.count(tasks, &(&1.status == status))

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :selected_task, selected_task(assigns))

    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar><.sidebar_nav current_path="/tasks" /></:sidebar>
      <:topbar><.top_bar project_name="CCEM APM" /></:topbar>
      <:main>
        <%!-- Page header --%>
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
          <div style="display: flex; align-items: center; gap: 12px;">
            <h1 style="margin: 0; font-size: 16px; font-weight: 600; color: var(--ccem-fg);">Background Tasks</h1>
            <.badge tone="neutral"><%= to_string(length(@tasks)) %> tasks</.badge>
          </div>
          <.segmented_control options={["all", "running", "completed", "failed", "stopped"]} active={@filter} on_change="filter" />
        </div>

        <%!-- Stat tiles --%>
        <div style="display: flex; gap: 12px; margin-bottom: 16px; flex-wrap: wrap;">
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Total" value={to_string(length(@tasks))} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Running" value={to_string(count_by_status(@tasks, "running"))} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Completed" value={to_string(count_by_status(@tasks, "completed"))} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Failed" value={to_string(count_by_status(@tasks, "failed"))} />
          </.card>
        </div>

        <%!-- Tasks table --%>
        <.card padded={false}>
          <.data_table id="tasks-table" rows={@tasks}>
            <:col :let={row} label="Name"><%= row[:name] %></:col>
            <:col :let={row} label="Definition"><span style="font-family: monospace; font-size: 11px; color: var(--ccem-fg-muted);"><%= row[:definition] %></span></:col>
            <:col :let={row} label="Status"><.badge tone={status_tone(row[:status])}><%= row[:status] %></.badge></:col>
            <:col :let={row} label="Runtime"><span style="color: var(--ccem-fg-muted);"><%= format_runtime(row[:runtime_seconds]) %></span></:col>
            <:col :let={row} label="Project"><span style="color: var(--ccem-fg-muted);"><%= row[:project] %></span></:col>
            <:col :let={row} label="Invoked By"><span style="font-size: 11px; color: var(--ccem-fg-muted);"><%= row[:invoking_process] %></span></:col>
            <:col :let={row} label="Actions">
              <div style="display: flex; gap: 6px;">
                <.btn variant="ghost" size="xs" phx-click="view_logs" phx-value-id={row[:id]}>Logs</.btn>
                <.btn :if={row[:status] == "running"} variant="destructive" size="xs" phx-click="stop_task" phx-value-id={row[:id]}>Stop</.btn>
                <.btn :if={row[:status] in ["completed", "failed", "stopped"]} variant="ghost" size="xs" phx-click="delete_task" phx-value-id={row[:id]}>Delete</.btn>
              </div>
            </:col>
          </.data_table>
        </.card>
      </:main>
    </.page_layout>

    <%!-- Logs Modal --%>
    <div :if={@selected_task} style="position: fixed; inset: 0; background: rgba(0,0,0,0.5); display: flex; align-items: center; justify-content: center; z-index: 50;" phx-click="close_logs">
      <div style="background: var(--ccem-surface-1); border: 1px solid var(--ccem-border); border-radius: 12px; width: 75%; max-height: 75vh; display: flex; flex-direction: column;" phx-click-stop>
        <div style="display: flex; align-items: center; justify-content: space-between; padding: 12px 16px; border-bottom: 1px solid var(--ccem-border);">
          <span style="font-size: 13px; font-weight: 600; color: var(--ccem-fg);"><%= @selected_task.name %> — Logs</span>
          <.btn variant="ghost" size="xs" phx-click="close_logs">Close</.btn>
        </div>
        <div style="padding: 16px; overflow: auto; font-family: monospace; font-size: 11px; color: var(--ccem-ok, #22c55e); background: var(--ccem-surface-2); max-height: 384px;">
          <div :if={@selected_task.logs == []} style="color: var(--ccem-fg-muted);">No log entries</div>
          <div :for={line <- @selected_task.logs}><%= line %></div>
        </div>
      </div>
    </div>
    """
  end
end
