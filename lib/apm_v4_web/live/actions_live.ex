defmodule ApmV4Web.ActionsLive do
  use ApmV4Web, :live_view

  alias ApmV4.ActionEngine

  @refresh_interval 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end

    {:ok,
     socket
     |> assign(:page_title, "Actions")
     |> assign(:catalog, ActionEngine.list_catalog())
     |> assign(:runs, ActionEngine.list_runs())
     |> assign(:show_modal, false)
     |> assign(:selected_action, nil)
     |> assign(:project_path, "")
     |> assign(:selected_run, nil)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, :runs, ActionEngine.list_runs())}
  end

  @impl true
  def handle_event("open_run_modal", %{"action" => action_id}, socket) do
    action = Enum.find(socket.assigns.catalog, &(&1.id == action_id))
    {:noreply, socket |> assign(:show_modal, true) |> assign(:selected_action, action) |> assign(:project_path, "")}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, socket |> assign(:show_modal, false) |> assign(:selected_action, nil) |> assign(:selected_run, nil)}
  end

  def handle_event("update_path", %{"project_path" => path}, socket) do
    {:noreply, assign(socket, :project_path, path)}
  end

  def handle_event("run_action", %{"project_path" => path}, socket) do
    action = socket.assigns.selected_action
    case ActionEngine.run_action(action.id, path) do
      {:ok, _run_id} ->
        {:noreply,
         socket
         |> assign(:show_modal, false)
         |> assign(:selected_action, nil)
         |> assign(:runs, ActionEngine.list_runs())
         |> put_flash(:info, "Action started: #{action.name}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{reason}")}
    end
  end

  def handle_event("view_result", %{"id" => run_id}, socket) do
    run =
      case ActionEngine.get_run(run_id) do
        {:ok, r} -> r
        _ -> nil
      end
    {:noreply, assign(socket, :selected_run, run)}
  end

  defp run_status_class("completed"), do: "badge badge-green"
  defp run_status_class("failed"), do: "badge badge-red"
  defp run_status_class("running"), do: "badge badge-blue"
  defp run_status_class(_), do: "badge badge-gray"

  defp category_color("hooks"), do: "text-yellow-400"
  defp category_color("memory"), do: "text-blue-400"
  defp category_color("config"), do: "text-green-400"
  defp category_color("analysis"), do: "text-purple-400"
  defp category_color(_), do: "text-gray-400"

  defp format_duration(nil, _), do: "-"
  defp format_duration(started, completed) do
    case {DateTime.from_iso8601(started), DateTime.from_iso8601(completed)} do
      {{:ok, s, _}, {:ok, c, _}} ->
        diff = DateTime.diff(c, s)
        "#{diff}s"
      _ -> "-"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-gray-950 text-gray-100">
      <!-- Sidebar -->
      <nav class="w-56 flex-shrink-0 bg-gray-900 border-r border-gray-800 flex flex-col py-4">
        <div class="px-4 mb-6">
          <span class="text-xs font-semibold text-gray-400 uppercase tracking-wider">CCEM APM</span>
        </div>
        <.link navigate="/" class="sidebar-link"><span>Dashboard</span></.link>
        <.link navigate="/tasks" class="sidebar-link"><span>Background Tasks</span></.link>
        <.link navigate="/scanner" class="sidebar-link"><span>Project Scanner</span></.link>
        <.link navigate="/actions" class="sidebar-link sidebar-link-active"><span>Actions</span></.link>
        <.link navigate="/formation" class="sidebar-link"><span>Formations</span></.link>
        <.link navigate="/ports" class="sidebar-link"><span>Ports</span></.link>
        <.link navigate="/notifications" class="sidebar-link"><span>Notifications</span></.link>
      </nav>

      <!-- Main content -->
      <div class="flex-1 flex flex-col overflow-hidden">
        <!-- Header -->
        <div class="bg-gray-900 border-b border-gray-800 px-6 py-4">
          <h1 class="text-lg font-semibold">Actions</h1>
          <p class="text-xs text-gray-400 mt-1">Run predefined actions to configure and update project APM integration</p>
        </div>

        <div class="flex-1 overflow-auto p-6 space-y-8">
          <!-- Action Catalog -->
          <div>
            <h2 class="text-sm font-semibold text-gray-400 uppercase tracking-wider mb-4">Action Catalog</h2>
            <div class="grid grid-cols-2 gap-4">
              <%= for action <- @catalog do %>
                <div class="bg-gray-900 border border-gray-800 rounded-lg p-4">
                  <div class="flex items-start justify-between mb-2">
                    <div>
                      <span class={"text-xs font-semibold uppercase #{category_color(action.category)}"}>
                        <%= action.category %>
                      </span>
                      <h3 class="font-medium mt-0.5"><%= action.name %></h3>
                    </div>
                  </div>
                  <p class="text-xs text-gray-400 mb-3"><%= action.description %></p>
                  <button
                    phx-click="open_run_modal"
                    phx-value-action={action.id}
                    class="btn-sm btn-primary w-full"
                  >
                    Run
                  </button>
                </div>
              <% end %>
            </div>
          </div>

          <!-- Recent Runs -->
          <div>
            <h2 class="text-sm font-semibold text-gray-400 uppercase tracking-wider mb-4">Recent Runs</h2>
            <%= if @runs == [] do %>
              <p class="text-gray-500 text-sm">No runs yet. Run an action above to get started.</p>
            <% else %>
              <table class="w-full text-sm">
                <thead>
                  <tr class="text-left text-gray-400 border-b border-gray-800">
                    <th class="pb-3 pr-4">Action</th>
                    <th class="pb-3 pr-4">Project</th>
                    <th class="pb-3 pr-4">Status</th>
                    <th class="pb-3 pr-4">Started</th>
                    <th class="pb-3 pr-4">Duration</th>
                    <th class="pb-3">Result</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for run <- @runs do %>
                    <tr class="border-b border-gray-800/50 hover:bg-gray-800/30">
                      <td class="py-3 pr-4 font-medium"><%= run.action_type %></td>
                      <td class="py-3 pr-4 text-gray-400 max-w-xs truncate"><%= run.project_path %></td>
                      <td class="py-3 pr-4">
                        <span class={run_status_class(run.status)}><%= run.status %></span>
                      </td>
                      <td class="py-3 pr-4 text-gray-400 text-xs"><%= run.started_at %></td>
                      <td class="py-3 pr-4 text-gray-400">
                        <%= format_duration(run.started_at, run.completed_at) %>
                      </td>
                      <td class="py-3">
                        <button phx-click="view_result" phx-value-id={run.id} class="btn-xs">
                          View
                        </button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            <% end %>
          </div>
        </div>
      </div>
    </div>

    <!-- Run Action Modal -->
    <%= if @show_modal and @selected_action do %>
      <div class="fixed inset-0 bg-black/50 flex items-center justify-center z-50" phx-click="close_modal">
        <div class="bg-gray-900 rounded-lg border border-gray-700 w-96" phx-click-stop>
          <div class="flex items-center justify-between px-4 py-3 border-b border-gray-700">
            <h3 class="font-medium">Run: <%= @selected_action.name %></h3>
            <button phx-click="close_modal" class="text-gray-400 hover:text-gray-100">✕</button>
          </div>
          <form phx-submit="run_action" class="p-4 space-y-3">
            <div>
              <label class="text-xs text-gray-400 block mb-1">Project Path</label>
              <input
                type="text"
                name="project_path"
                value={@project_path}
                phx-change="update_path"
                placeholder="~/Developer/my-project"
                class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-blue-500"
                autofocus
              />
            </div>
            <p class="text-xs text-gray-400"><%= @selected_action.description %></p>
            <div class="flex justify-end gap-2">
              <button type="button" phx-click="close_modal" class="btn-sm btn-ghost">Cancel</button>
              <button type="submit" class="btn-sm btn-primary">Run Action</button>
            </div>
          </form>
        </div>
      </div>
    <% end %>

    <!-- Result Modal -->
    <%= if @selected_run do %>
      <div class="fixed inset-0 bg-black/50 flex items-center justify-center z-50" phx-click="close_modal">
        <div class="bg-gray-900 rounded-lg border border-gray-700 w-2/3 max-h-2/3 flex flex-col" phx-click-stop>
          <div class="flex items-center justify-between px-4 py-3 border-b border-gray-700">
            <h3 class="font-medium"><%= @selected_run.action_type %> Result</h3>
            <button phx-click="close_modal" class="text-gray-400 hover:text-gray-100">✕</button>
          </div>
          <div class="p-4 overflow-auto">
            <%= if @selected_run.error do %>
              <p class="text-red-400 text-sm"><%= @selected_run.error %></p>
            <% else %>
              <pre class="text-xs text-green-400 whitespace-pre-wrap"><%= inspect(@selected_run.result, pretty: true) %></pre>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end
