defmodule ApmV5Web.TasksLive do
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
     |> load_tasks()}
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

  defp status_badge_class("running"), do: "badge badge-blue"
  defp status_badge_class("completed"), do: "badge badge-green"
  defp status_badge_class("failed"), do: "badge badge-red"
  defp status_badge_class("stopped"), do: "badge badge-gray"
  defp status_badge_class(_), do: "badge badge-gray"

  defp format_runtime(seconds) when is_integer(seconds) and seconds >= 60 do
    m = div(seconds, 60)
    s = rem(seconds, 60)
    "#{m}m #{s}s"
  end
  defp format_runtime(seconds) when is_integer(seconds), do: "#{seconds}s"
  defp format_runtime(_), do: "-"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :selected_task, selected_task(assigns))

    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <.sidebar_nav current_path="/tasks" />

      <%!-- Main content --%>
      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Header --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Background Tasks</h2>
            <div class="badge badge-sm badge-ghost"><%= length(@tasks) %> tasks</div>
          </div>
          <div class="flex gap-1">
            <button :for={status <- ["all", "running", "completed", "failed", "stopped"]}
              phx-click="filter"
              phx-value-status={status}
              class={["btn btn-xs", if(@filter == status, do: "btn-primary", else: "btn-ghost")]}>
              <%= String.capitalize(status) %>
            </button>
          </div>
        </header>

        <%!-- Table --%>
        <div class="flex-1 overflow-auto p-4">
          <table class="w-full text-sm">
            <thead>
              <tr class="text-left text-base-content/50 border-b border-base-300">
                <th class="pb-3 pr-4">Name</th>
                <th class="pb-3 pr-4">Definition</th>
                <th class="pb-3 pr-4">Status</th>
                <th class="pb-3 pr-4">Runtime</th>
                <th class="pb-3 pr-4">Project</th>
                <th class="pb-3 pr-4">Invoked By</th>
                <th class="pb-3">Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= if @tasks == [] do %>
                <tr>
                  <td colspan="7" class="py-8 text-center text-base-content/40">No tasks found</td>
                </tr>
              <% else %>
                <%= for task <- @tasks do %>
                  <tr class="border-b border-base-300/50 hover:bg-base-200/50">
                    <td class="py-3 pr-4 font-medium text-base-content"><%= task.name %></td>
                    <td class="py-3 pr-4 text-base-content/60 max-w-xs truncate"><%= task.definition %></td>
                    <td class="py-3 pr-4">
                      <span class={status_badge_class(task.status)}><%= task.status %></span>
                    </td>
                    <td class="py-3 pr-4 text-base-content/60"><%= format_runtime(task.runtime_seconds) %></td>
                    <td class="py-3 pr-4 text-base-content/60"><%= task.project %></td>
                    <td class="py-3 pr-4 text-base-content/60 max-w-xs truncate"><%= task.invoking_process %></td>
                    <td class="py-3">
                      <div class="flex gap-2">
                        <button phx-click="view_logs" phx-value-id={task.id} class="btn btn-ghost btn-xs">
                          Logs
                        </button>
                        <%= if task.status == "running" do %>
                          <button phx-click="stop_task" phx-value-id={task.id} class="btn btn-error btn-xs">
                            Stop
                          </button>
                        <% end %>
                        <%= if task.status in ["completed", "failed", "stopped"] do %>
                          <button phx-click="delete_task" phx-value-id={task.id} class="btn btn-ghost btn-xs">
                            Delete
                          </button>
                        <% end %>
                      </div>
                    </td>
                  </tr>
                <% end %>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>

    <%!-- Logs Modal --%>
    <%= if @selected_task do %>
      <div class="fixed inset-0 bg-black/50 flex items-center justify-center z-50" phx-click="close_logs">
        <div class="bg-base-200 rounded-xl border border-base-300 w-3/4 max-h-3/4 flex flex-col" phx-click-stop>
          <div class="flex items-center justify-between px-4 py-3 border-b border-base-300">
            <h3 class="text-sm font-semibold text-base-content"><%= @selected_task.name %> — Logs</h3>
            <button phx-click="close_logs" class="btn btn-ghost btn-xs btn-circle">
              <.icon name="hero-x-mark" class="size-3" />
            </button>
          </div>
          <div class="p-4 overflow-auto font-mono text-xs text-success bg-base-300/50 max-h-96">
            <%= if @selected_task.logs == [] do %>
              <p class="text-base-content/40">No log entries</p>
            <% else %>
              <%= for line <- @selected_task.logs do %>
                <div><%= line %></div>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end
