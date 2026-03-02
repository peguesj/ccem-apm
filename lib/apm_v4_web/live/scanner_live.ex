defmodule ApmV4Web.ScannerLive do
  use ApmV4Web, :live_view

  alias ApmV4.ProjectScanner

  @refresh_interval 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end

    status =
      try do ProjectScanner.get_status()
      rescue _ -> %{status: :offline, message: "ProjectScanner not running"}
      catch :exit, _ -> %{status: :offline, message: "ProjectScanner not running"}
      end

    results =
      try do ProjectScanner.get_results()
      rescue _ -> []
      catch :exit, _ -> []
      end

    {:ok,
     socket
     |> assign(:page_title, "Project Scanner")
     |> assign(:base_path, "~/Developer")
     |> assign(:scanning, false)
     |> assign(:scanner_status, status)
     |> assign(:results, results)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    status =
      try do ProjectScanner.get_status()
      rescue _ -> %{status: :offline, message: "ProjectScanner not running"}
      catch :exit, _ -> %{status: :offline, message: "ProjectScanner not running"}
      end
    scanning = status.status == :scanning

    socket =
      socket
      |> assign(:scanner_status, status)
      |> assign(:scanning, scanning)

    socket =
      if not scanning and socket.assigns.scanning do
        results = try do ProjectScanner.get_results() rescue _ -> [] catch :exit, _ -> [] end
        assign(socket, :results, results)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("scan", %{"base_path" => path}, socket) do
    Task.start(fn ->
      try do ProjectScanner.scan(path) rescue _ -> :ok catch :exit, _ -> :ok end
    end)
    {:noreply, socket |> assign(:scanning, true) |> assign(:base_path, path)}
  end

  def handle_event("update_path", %{"base_path" => path}, socket) do
    {:noreply, assign(socket, :base_path, path)}
  end

  # --- Components ---

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :href, :string, required: true
  attr :badge, :any, default: nil

  defp nav_item(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "flex items-center gap-3 px-3 py-2 rounded text-sm transition-colors",
        @active && "bg-primary/10 text-primary font-medium",
        !@active && "text-base-content/60 hover:text-base-content hover:bg-base-300"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
      <span :if={@badge && @badge > 0} class="badge badge-xs badge-primary ml-auto">{@badge}</span>
    </a>
    """
  end

  # --- Helpers ---

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
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <%!-- Sidebar --%>
      <aside class="w-56 bg-base-200 border-r border-base-300 flex flex-col flex-shrink-0">
        <div class="p-4 border-b border-base-300">
          <h1 class="text-lg font-bold text-primary flex items-center gap-2">
            <span class="inline-block w-2 h-2 rounded-full bg-success animate-pulse"></span>
            CCEM APM v4
          </h1>
          <p class="text-xs text-base-content/50 mt-1">Agent Performance Monitor</p>
        </div>
        <nav class="flex-1 p-2 space-y-1 overflow-y-auto">
          <.nav_item icon="hero-squares-2x2" label="Dashboard" active={false} href="/" />
          <.nav_item icon="hero-globe-alt" label="All Projects" active={false} href="/apm-all" />
          <.nav_item icon="hero-rectangle-group" label="Formations" active={false} href="/formation" />
          <.nav_item icon="hero-circle-stack" label="UPM" active={false} href="/upm" />
          <.nav_item icon="hero-clock" label="Timeline" active={false} href="/timeline" />
          <.nav_item icon="hero-bell" label="Notifications" active={false} href="/notifications" />
          <.nav_item icon="hero-queue-list" label="Background Tasks" active={false} href="/tasks" />
          <.nav_item icon="hero-magnifying-glass" label="Project Scanner" active={true} href="/scanner" />
          <.nav_item icon="hero-bolt" label="Actions" active={false} href="/actions" />
          <.nav_item icon="hero-sparkles" label="Skills" active={false} href="/skills" />
          <.nav_item icon="hero-arrow-path" label="Ralph" active={false} href="/ralph" />
          <.nav_item icon="hero-signal" label="Ports" active={false} href="/ports" />
          <.nav_item icon="hero-book-open" label="Docs" active={false} href="/docs" />
        </nav>
      </aside>

      <%!-- Main content --%>
      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Header --%>
        <header class="bg-base-200 border-b border-base-300 flex-shrink-0">
          <div class="h-12 flex items-center justify-between px-4">
            <div class="flex items-center gap-3">
              <h2 class="text-sm font-semibold text-base-content">Project Scanner</h2>
              <span class="text-xs text-base-content/40"><%= scanner_status_text(@scanner_status) %></span>
            </div>
          </div>
          <div class="px-4 pb-3">
            <form phx-submit="scan" class="flex gap-2">
              <input
                type="text"
                name="base_path"
                value={@base_path}
                phx-change="update_path"
                placeholder="~/Developer"
                class="input input-bordered input-sm flex-1 bg-base-100 text-sm"
              />
              <button type="submit" disabled={@scanning} class="btn btn-primary btn-sm">
                <%= if @scanning do %>
                  <span class="animate-pulse">Scanning…</span>
                <% else %>
                  Scan
                <% end %>
              </button>
            </form>
          </div>
        </header>

        <%!-- Results --%>
        <div class="flex-1 overflow-auto p-4">
          <%= if @results == [] and not @scanning do %>
            <div class="text-center text-base-content/40 py-12">
              <p>No results yet. Enter a base path and click Scan.</p>
            </div>
          <% else %>
            <table class="w-full text-sm">
              <thead>
                <tr class="text-left text-base-content/50 border-b border-base-300">
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
                  <tr class="border-b border-base-300/50 hover:bg-base-200/50">
                    <td class="py-3 pr-4 font-medium text-base-content"><%= project.name %></td>
                    <td class="py-3 pr-4">
                      <div class="flex flex-wrap gap-1">
                        <%= for lang <- project.stack do %>
                          <span class={"badge #{stack_badge_class(lang)}"}><%= lang %></span>
                        <% end %>
                      </div>
                    </td>
                    <td class="py-3 pr-4 text-base-content/60">
                      <%= if project.ports == [] do %>
                        <span class="text-base-content/30">—</span>
                      <% else %>
                        <%= Enum.join(project.ports, ", ") %>
                      <% end %>
                    </td>
                    <td class="py-3 pr-4">
                      <%= if project.has_claude_config do %>
                        <span class="text-success">✓</span>
                      <% else %>
                        <span class="text-base-content/30">✗</span>
                      <% end %>
                    </td>
                    <td class="py-3 pr-4 text-base-content/60"><%= project.agent_count %></td>
                    <td class="py-3 pr-4 text-base-content/60"><%= project.formation_count %></td>
                    <td class="py-3 text-xs text-base-content/40 font-mono truncate max-w-xs"><%= project.path %></td>
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
