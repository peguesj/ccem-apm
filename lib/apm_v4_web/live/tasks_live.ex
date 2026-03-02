defmodule ApmV4Web.TasksLive do
  use ApmV4Web, :live_view

  alias ApmV4.BackgroundTasksStore

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
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
    BackgroundTasksStore.stop_task(id)
    {:noreply, load_tasks(socket)}
  end

  def handle_event("delete_task", %{"id" => id}, socket) do
    BackgroundTasksStore.delete_task(id)
    {:noreply, load_tasks(socket)}
  end

  defp load_tasks(socket) do
    filter = socket.assigns[:filter] || "all"

    filter_map = if filter == "all", do: %{}, else: %{status: filter}
    tasks = BackgroundTasksStore.list_tasks(filter_map)

    assign(socket, :tasks, tasks)
  end

  defp selected_task(socket) do
    case socket.assigns[:selected_task_id] do
      nil -> nil
      id ->
        case BackgroundTasksStore.get_task(id) do
          {:ok, task} -> task
          _ -> nil
        end
    end
  end

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
    <div class="flex h-screen bg-gray-950 text-gray-100">
      <!-- Sidebar -->
      <nav class="w-56 flex-shrink-0 bg-gray-900 border-r border-gray-800 flex flex-col py-4">
        <div class="px-4 mb-6">
          <span class="text-xs font-semibold text-gray-400 uppercase tracking-wider">CCEM APM</span>
        </div>
        <.link navigate="/" class="sidebar-link"><span>Dashboard</span></.link>
        <.link navigate="/tasks" class="sidebar-link sidebar-link-active"><span>Background Tasks</span></.link>
        <.link navigate="/scanner" class="sidebar-link"><span>Project Scanner</span></.link>
        <.link navigate="/actions" class="sidebar-link"><span>Actions</span></.link>
        <.link navigate="/formation" class="sidebar-link"><span>Formations</span></.link>
        <.link navigate="/ports" class="sidebar-link"><span>Ports</span></.link>
        <.link navigate="/notifications" class="sidebar-link"><span>Notifications</span></.link>
      </nav>

      <!-- Main content -->
      <div class="flex-1 flex flex-col overflow-hidden">
        <!-- Header -->
        <div class="bg-gray-900 border-b border-gray-800 px-6 py-4 flex items-center justify-between">
          <div class="flex items-center gap-3">
            <h1 class="text-lg font-semibold">Background Tasks</h1>
            <span class="badge badge-gray"><%= length(@tasks) %> tasks</span>
          </div>
          <div class="flex gap-2">
            <%= for status <- ["all", "running", "completed", "failed", "stopped"] do %>
              <button
                phx-click="filter"
                phx-value-status={status}
                class={"filter-btn #{if @filter == status, do: "filter-btn-active", else: ""}"}
              >
                <%= String.capitalize(status) %>
              </button>
            <% end %>
          </div>
        </div>

        <!-- Table -->
        <div class="flex-1 overflow-auto p-6">
          <table class="w-full text-sm">
            <thead>
              <tr class="text-left text-gray-400 border-b border-gray-800">
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
                  <td colspan="7" class="py-8 text-center text-gray-500">No tasks found</td>
                </tr>
              <% else %>
                <%= for task <- @tasks do %>
                  <tr class="border-b border-gray-800/50 hover:bg-gray-800/30">
                    <td class="py-3 pr-4 font-medium"><%= task.name %></td>
                    <td class="py-3 pr-4 text-gray-400 max-w-xs truncate"><%= task.definition %></td>
                    <td class="py-3 pr-4">
                      <span class={status_badge_class(task.status)}><%= task.status %></span>
                    </td>
                    <td class="py-3 pr-4 text-gray-400"><%= format_runtime(task.runtime_seconds) %></td>
                    <td class="py-3 pr-4 text-gray-400"><%= task.project %></td>
                    <td class="py-3 pr-4 text-gray-400 max-w-xs truncate"><%= task.invoking_process %></td>
                    <td class="py-3">
                      <div class="flex gap-2">
                        <button phx-click="view_logs" phx-value-id={task.id} class="btn-xs">
                          Logs
                        </button>
                        <%= if task.status == "running" do %>
                          <button phx-click="stop_task" phx-value-id={task.id} class="btn-xs btn-red">
                            Stop
                          </button>
                        <% end %>
                        <%= if task.status in ["completed", "failed", "stopped"] do %>
                          <button phx-click="delete_task" phx-value-id={task.id} class="btn-xs btn-ghost">
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

    <!-- Logs Modal -->
    <%= if @selected_task do %>
      <div class="fixed inset-0 bg-black/50 flex items-center justify-center z-50" phx-click="close_logs">
        <div class="bg-gray-900 rounded-lg border border-gray-700 w-3/4 max-h-3/4 flex flex-col" phx-click-stop>
          <div class="flex items-center justify-between px-4 py-3 border-b border-gray-700">
            <h3 class="font-medium"><%= @selected_task.name %> — Logs</h3>
            <button phx-click="close_logs" class="text-gray-400 hover:text-gray-100">✕</button>
          </div>
          <div class="p-4 overflow-auto font-mono text-xs text-green-400 bg-black/30 max-h-96">
            <%= if @selected_task.logs == [] do %>
              <p class="text-gray-500">No log entries</p>
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
