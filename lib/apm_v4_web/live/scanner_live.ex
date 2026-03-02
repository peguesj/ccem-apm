defmodule ApmV4Web.ScannerLive do
  use ApmV4Web, :live_view

  alias ApmV4.ProjectScanner

  @refresh_interval 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end

    status = ProjectScanner.get_status()

    {:ok,
     socket
     |> assign(:page_title, "Project Scanner")
     |> assign(:base_path, "~/Developer")
     |> assign(:scanning, false)
     |> assign(:scanner_status, status)
     |> assign(:results, ProjectScanner.get_results())}
  end

  @impl true
  def handle_info(:refresh, socket) do
    status = ProjectScanner.get_status()
    scanning = status.status == :scanning

    socket =
      socket
      |> assign(:scanner_status, status)
      |> assign(:scanning, scanning)

    socket =
      if not scanning and socket.assigns.scanning do
        assign(socket, :results, ProjectScanner.get_results())
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("scan", %{"base_path" => path}, socket) do
    Task.start(fn -> ProjectScanner.scan(path) end)
    {:noreply, socket |> assign(:scanning, true) |> assign(:base_path, path)}
  end

  def handle_event("update_path", %{"base_path" => path}, socket) do
    {:noreply, assign(socket, :base_path, path)}
  end

  defp stack_badge_class("node"), do: "badge-yellow"
  defp stack_badge_class("elixir"), do: "badge-purple"
  defp stack_badge_class("python"), do: "badge-blue"
  defp stack_badge_class("rust"), do: "badge-orange"
  defp stack_badge_class("go"), do: "badge-cyan"
  defp stack_badge_class("swift"), do: "badge-pink"
  defp stack_badge_class(_), do: "badge-gray"

  defp scanner_status_text(%{status: :idle}), do: "Idle — not yet scanned"
  defp scanner_status_text(%{status: :scanning}), do: "Scanning..."
  defp scanner_status_text(%{status: :done, project_count: n, scanned_at: ts}) do
    "Last scan: #{relative_time(ts)} · #{n} projects found"
  end
  defp scanner_status_text(_), do: "Unknown"

  defp relative_time(nil), do: "never"
  defp relative_time(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        diff = DateTime.diff(DateTime.utc_now(), dt)
        cond do
          diff < 60 -> "#{diff}s ago"
          diff < 3600 -> "#{div(diff, 60)}m ago"
          true -> "#{div(diff, 3600)}h ago"
        end
      _ -> iso
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
        <.link navigate="/scanner" class="sidebar-link sidebar-link-active"><span>Project Scanner</span></.link>
        <.link navigate="/actions" class="sidebar-link"><span>Actions</span></.link>
        <.link navigate="/formation" class="sidebar-link"><span>Formations</span></.link>
        <.link navigate="/ports" class="sidebar-link"><span>Ports</span></.link>
        <.link navigate="/notifications" class="sidebar-link"><span>Notifications</span></.link>
      </nav>

      <!-- Main content -->
      <div class="flex-1 flex flex-col overflow-hidden">
        <!-- Header -->
        <div class="bg-gray-900 border-b border-gray-800 px-6 py-4">
          <div class="flex items-center justify-between mb-3">
            <h1 class="text-lg font-semibold">Project Scanner</h1>
            <span class="text-xs text-gray-400"><%= scanner_status_text(@scanner_status) %></span>
          </div>
          <form phx-submit="scan" class="flex gap-2">
            <input
              type="text"
              name="base_path"
              value={@base_path}
              phx-change="update_path"
              placeholder="~/Developer"
              class="flex-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-blue-500"
            />
            <button
              type="submit"
              disabled={@scanning}
              class="btn-primary"
            >
              <%= if @scanning do %>
                <span class="animate-pulse">Scanning...</span>
              <% else %>
                Scan
              <% end %>
            </button>
          </form>
        </div>

        <!-- Results -->
        <div class="flex-1 overflow-auto p-6">
          <%= if @results == [] and not @scanning do %>
            <div class="text-center text-gray-500 py-12">
              <p>No results yet. Enter a base path and click Scan.</p>
            </div>
          <% else %>
            <table class="w-full text-sm">
              <thead>
                <tr class="text-left text-gray-400 border-b border-gray-800">
                  <th class="pb-3 pr-4">Name</th>
                  <th class="pb-3 pr-4">Stack</th>
                  <th class="pb-3 pr-4">Ports</th>
                  <th class="pb-3 pr-4">Claude Config</th>
                  <th class="pb-3 pr-4">Agents</th>
                  <th class="pb-3 pr-4">Formations</th>
                  <th class="pb-3">Path</th>
                </tr>
              </thead>
              <tbody>
                <%= for project <- @results do %>
                  <tr class="border-b border-gray-800/50 hover:bg-gray-800/30">
                    <td class="py-3 pr-4 font-medium"><%= project.name %></td>
                    <td class="py-3 pr-4">
                      <div class="flex flex-wrap gap-1">
                        <%= for lang <- project.stack do %>
                          <span class={"badge #{stack_badge_class(lang)}"}><%= lang %></span>
                        <% end %>
                      </div>
                    </td>
                    <td class="py-3 pr-4 text-gray-400">
                      <%= if project.ports == [] do %>
                        <span class="text-gray-600">—</span>
                      <% else %>
                        <%= Enum.join(project.ports, ", ") %>
                      <% end %>
                    </td>
                    <td class="py-3 pr-4">
                      <%= if project.has_claude_config do %>
                        <span class="text-green-400">✓</span>
                      <% else %>
                        <span class="text-gray-600">✗</span>
                      <% end %>
                    </td>
                    <td class="py-3 pr-4 text-gray-400"><%= project.agent_count %></td>
                    <td class="py-3 pr-4 text-gray-400"><%= project.formation_count %></td>
                    <td class="py-3 text-xs text-gray-500 font-mono truncate max-w-xs"><%= project.path %></td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
