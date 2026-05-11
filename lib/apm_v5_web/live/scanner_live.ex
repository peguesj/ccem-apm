defmodule ApmV5Web.ScannerLive do
  @moduledoc """
  LiveView for the project scanner at /scanner.

  Displays developer directory scan results: detected projects, stack
  badges, port assignments, and formation activity counts.
  """

  use ApmV5Web, :live_view


  alias ApmV5.ProjectScanner

  @refresh_interval 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
      # US-021: EventBus subscription for AG-UI activity events
      ApmV5.AgUi.EventBus.subscribe("activity:*")
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
     |> assign(:results, results)
     |> assign(:sidebar_collapsed, false)
     |> assign(:inspector_open, false)
     |> assign(:selected_project, nil)
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
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

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_collapsed: !socket.assigns.sidebar_collapsed)}
  end

  def handle_event("toggle_inspector", _params, socket) do
    {:noreply, assign(socket, inspector_open: !socket.assigns.inspector_open)}
  end

  def handle_event("select_project", %{"path" => path}, socket) do
    selected = Enum.find(socket.assigns.results, fn r -> r[:path] == path end)

    {:noreply,
     socket
     |> assign(:selected_project, selected)
     |> assign(:inspector_open, selected != nil)}
  end

  def handle_event("close_inspector", _params, socket) do
    {:noreply, socket |> assign(:inspector_open, false) |> assign(:selected_project, nil)}
  end

  # --- Helpers ---

  defp stack_tone("node"), do: "warn"
  defp stack_tone("elixir"), do: "accent"
  defp stack_tone("python"), do: "iris"
  defp stack_tone("rust"), do: "err"
  defp stack_tone("go"), do: "info"
  defp stack_tone("swift"), do: "ok"
  defp stack_tone(_), do: "neutral"

  defp scanner_status_tone(%{status: :idle}), do: "neutral"
  defp scanner_status_tone(%{status: :scanning}), do: "info"
  defp scanner_status_tone(%{status: :done}), do: "ok"
  defp scanner_status_tone(_), do: "neutral"

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
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar><.sidebar_nav current_path="/scanner" /></:sidebar>
      <:topbar><.top_bar project_name="CCEM APM" /></:topbar>
      <:main>
        <%!-- Page header --%>
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
          <div style="display: flex; align-items: center; gap: 12px;">
            <h1 style="margin: 0; font-size: 16px; font-weight: 600; color: var(--ccem-fg);">Project Scanner</h1>
            <.badge tone={scanner_status_tone(@scanner_status)}><%= scanner_status_text(@scanner_status) %></.badge>
          </div>
          <form phx-submit="scan" style="display: flex; align-items: center; gap: 8px;">
            <.ds_input type="text" name="base_path" value={@base_path} phx-change="update_path" placeholder="~/Developer" />
            <.btn variant="primary" size="sm" type="submit" disabled={@scanning}>
              <%= if @scanning, do: "Scanning...", else: "Run Scan" %>
            </.btn>
          </form>
        </div>

        <%!-- Stat tiles --%>
        <div style="display: flex; gap: 12px; margin-bottom: 16px; flex-wrap: wrap;">
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Projects Found" value={to_string(length(@results))} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="With Claude Config" value={to_string(Enum.count(@results, & &1[:has_claude_config]))} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Total Agents" value={to_string(Enum.sum(Enum.map(@results, & (&1[:agent_count] || 0))))} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Formations" value={to_string(Enum.sum(Enum.map(@results, & (&1[:formation_count] || 0))))} />
          </.card>
        </div>

        <%!-- Empty state --%>
        <div :if={@results == [] and not @scanning} style="text-align: center; padding: 48px 0; color: var(--ccem-fg-muted);">
          No results yet. Enter a base path and click Run Scan.
        </div>

        <%!-- Scanning indicator --%>
        <div :if={@scanning and @results == []} style="text-align: center; padding: 48px 0; color: var(--ccem-fg-muted);">
          <.badge tone="info" dot={true}>Scanning...</.badge>
        </div>

        <%!-- Results table --%>
        <.card :if={@results != []} padded={false}>
          <.data_table id="scanner-results-table" rows={@results}>
            <:col :let={row} label="Name"><span style="font-weight: 500; color: var(--ccem-fg);"><%= row[:name] %></span></:col>
            <:col :let={row} label="Stack">
              <div style="display: flex; flex-wrap: wrap; gap: 4px;">
                <.badge :for={lang <- (row[:stack] || [])} tone={stack_tone(lang)} square={true}><%= lang %></.badge>
              </div>
            </:col>
            <:col :let={row} label="Ports">
              <span style="color: var(--ccem-fg-muted);">
                <%= if (row[:ports] || []) == [], do: "—", else: Enum.join(row[:ports], ", ") %>
              </span>
            </:col>
            <:col :let={row} label="Claude Config">
              <.badge tone={if row[:has_claude_config], do: "ok", else: "neutral"}>
                <%= if row[:has_claude_config], do: "yes", else: "no" %>
              </.badge>
            </:col>
            <:col :let={row} label="Agents"><span style="color: var(--ccem-fg-muted);"><%= row[:agent_count] || 0 %></span></:col>
            <:col :let={row} label="Formations"><span style="color: var(--ccem-fg-muted);"><%= row[:formation_count] || 0 %></span></:col>
            <:col :let={row} label="Path"><span style="font-size: 11px; font-family: monospace; color: var(--ccem-fg-subtle); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 240px; display: block;"><%= row[:path] %></span></:col>
            <:col :let={row} label="">
              <.btn variant="ghost" size="xs" phx-click="select_project" phx-value-path={row[:path]}>
                View
              </.btn>
            </:col>
          </.data_table>
        </.card>
      </:main>
      <:inspector>
        <%= if @selected_project do %>
          <div style="padding: var(--ccem-space-4); display: flex; flex-direction: column; gap: var(--ccem-space-3);">
            <div style="display: flex; align-items: center; justify-content: space-between;">
              <span style="font-size: var(--ccem-text-sm); font-weight: 600; color: var(--ccem-fg-primary);">Project Detail</span>
              <.btn variant="ghost" size="xs" phx-click="close_inspector">Close</.btn>
            </div>
            <div style="font-family: var(--ccem-font-mono); font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted); word-break: break-all;">
              <div><strong>Name:</strong> <%= @selected_project[:name] %></div>
              <div><strong>Path:</strong> <%= @selected_project[:path] %></div>
              <div><strong>Stack:</strong> <%= Enum.join(@selected_project[:stack] || [], ", ") %></div>
              <div><strong>Ports:</strong> <%= Enum.join(@selected_project[:ports] || [], ", ") %></div>
              <div><strong>Claude Config:</strong> <%= if @selected_project[:has_claude_config], do: "yes", else: "no" %></div>
              <div><strong>Agents:</strong> <%= @selected_project[:agent_count] || 0 %></div>
              <div><strong>Formations:</strong> <%= @selected_project[:formation_count] || 0 %></div>
            </div>
          </div>
        <% end %>
      </:inspector>
    </.page_layout>
    """
  end
end
