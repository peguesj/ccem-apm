defmodule ApmWeb.PortsLive do
  @moduledoc """
  LiveView for the Port Management Dashboard at `/ports`.

  Displays all port assignments registered with `Apm.PortManager`, provides
  conflict detection and one-click reassignment, and allows filtering by status
  (all / active / clashes) and namespace (web / api / service / tool).

  ## Features

  - Real-time updates via the `apm:ports` PubSub topic
  - Scan live ports on the host system to refresh active status
  - Detect and surface port clashes between projects
  - Assign the next available port in a namespace for a project
  - Visual port-range utilization bars per namespace

  ## PubSub

  Subscribes to `"apm:ports"` on mount (connected sockets only).
  Refreshes port map and clashes on `{:port_assigned, _, _}` messages.
  """

  use ApmWeb, :live_view


  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:ports")
      :timer.send_interval(10_000, self(), :refresh)
    end

    port_map = Apm.PortManager.get_port_map()
    clashes = Apm.PortManager.detect_clashes()
    ranges = Apm.PortManager.get_port_ranges()

    socket =
      socket
      |> assign(:page_title, "Ports")
      |> assign(:port_map, port_map)
      |> assign(:clashes, clashes)
      |> assign(:port_ranges, ranges)
      |> assign(:status_filter, "all")
      |> assign(:namespace_filter, "all")
      |> assign(:sidebar_collapsed, false)
      |> assign(:inspector_open, false)
      |> assign_derived(port_map, clashes)

    {:ok, ApmWeb.Components.SidebarNav.assign_sidebar_nav_data(socket)}
  end

  @impl true
  def handle_event("scan_ports", _params, socket) do
    Apm.PortManager.scan_active_ports()
    port_map = Apm.PortManager.get_port_map()
    clashes = Apm.PortManager.detect_clashes()

    {:noreply,
     socket
     |> assign(:port_map, port_map)
     |> assign(:clashes, clashes)
     |> assign_derived(port_map, clashes)}
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply, assign(socket, :status_filter, status) |> refilter()}
  end

  @impl true
  def handle_event("namespace_filter", %{"namespace" => ns}, socket) do
    {:noreply, assign(socket, :namespace_filter, ns) |> refilter()}
  end

  @impl true
  def handle_event("assign_port", %{"project" => project}, socket) do
    case Apm.PortManager.assign_port(project) do
      {:ok, _port} ->
        port_map = Apm.PortManager.get_port_map()
        clashes = Apm.PortManager.detect_clashes()
        {:noreply, socket |> assign(:port_map, port_map) |> assign(:clashes, clashes) |> assign_derived(port_map, clashes)}
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No available port")}
    end
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_collapsed: !socket.assigns.sidebar_collapsed)}
  end

  def handle_event("toggle_inspector", _params, socket) do
    {:noreply, assign(socket, inspector_open: !socket.assigns.inspector_open)}
  end

  @impl true
  def handle_info({:port_assigned, _, _}, socket) do
    port_map = Apm.PortManager.get_port_map()
    clashes = Apm.PortManager.detect_clashes()
    {:noreply, socket |> assign(:port_map, port_map) |> assign(:clashes, clashes) |> assign_derived(port_map, clashes)}
  end

  @impl true
  def handle_info({:ports_updated, _active}, socket) do
    port_map = Apm.PortManager.get_port_map()
    clashes = Apm.PortManager.detect_clashes()
    {:noreply, socket |> assign(:port_map, port_map) |> assign(:clashes, clashes) |> assign_derived(port_map, clashes)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    # scan_active_ports/0 dispatches an async Task that casts {:scan_result, active}
    # back to the GenServer. The LiveView will receive a {:ports_updated, _} PubSub
    # broadcast once the scan completes, so no immediate get_port_map/0 call is needed.
    Apm.PortManager.scan_active_ports()
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_derived(socket, port_map, clashes) do
    projects = to_list(port_map)
    clash_ports = MapSet.new(Enum.flat_map(clashes, fn c -> c.projects end))

    socket
    |> assign(:all_projects, projects)
    |> assign(:clash_ports, clash_ports)
    |> assign(:total, length(projects))
    |> assign(:active_count, Enum.count(projects, & &1.active))
    |> assign(:clash_count, length(clashes))
    |> refilter()
  end

  defp refilter(socket) do
    a = socket.assigns
    filtered = a.all_projects
      |> filter_status(a.status_filter, a.clash_ports)
      |> filter_ns(a.namespace_filter)
    assign(socket, :filtered, filtered)
  end

  defp to_list(pm) when is_map(pm) do
    Enum.map(pm, fn {port, info} ->
      %{name: info.project, port: port, namespace: info.namespace, active: info[:active] || false}
    end) |> Enum.sort_by(& &1.name)
  end
  defp to_list(_), do: []

  defp filter_status(p, "active", _), do: Enum.filter(p, & &1.active)
  defp filter_status(p, "clashes", cp), do: Enum.filter(p, &MapSet.member?(cp, &1.name))
  defp filter_status(p, _, _), do: p

  defp filter_ns(p, "all"), do: p
  defp filter_ns(p, ns), do: Enum.filter(p, &(to_string(&1.namespace) == ns))

  # --- Helpers ---

  defp ns_tone("web"), do: "iris"
  defp ns_tone("api"), do: "accent"
  defp ns_tone("service"), do: "warning"
  defp ns_tone("tool"), do: "success"
  defp ns_tone(_), do: "neutral"

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar><.sidebar_nav current_path="/ports" /></:sidebar>
      <:topbar><.top_bar project_name="CCEM APM" /></:topbar>
      <:main>
        <%!-- Page header --%>
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
          <div style="display: flex; align-items: center; gap: 12px;">
            <h1 style="margin: 0; font-size: 16px; font-weight: 600; color: var(--ccem-fg);">Port Manager</h1>
            <.badge tone="neutral"><%= to_string(@total) %> projects</.badge>
            <.badge tone="success"><%= to_string(@active_count) %> active</.badge>
            <.badge :if={@clash_count > 0} tone="error"><%= to_string(@clash_count) %> clashes</.badge>
          </div>
          <.btn variant="primary" size="sm" phx-click="scan_ports">Scan Ports</.btn>
        </div>

        <%!-- Stat tiles --%>
        <div style="display: flex; gap: 12px; margin-bottom: 16px; flex-wrap: wrap;">
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Total Projects" value={to_string(@total)} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Active" value={to_string(@active_count)} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Clashes" value={to_string(@clash_count)} />
          </.card>
        </div>

        <%!-- Filters --%>
        <.card style="margin-bottom: 16px; padding: 12px 16px;">
          <div style="display: flex; align-items: center; gap: 16px; flex-wrap: wrap;">
            <div style="display: flex; align-items: center; gap: 8px;">
              <span style="font-size: 11px; color: var(--ccem-fg-muted); text-transform: uppercase; letter-spacing: 0.05em;">Status</span>
              <.segmented_control options={["all", "active", "clashes"]} active={@status_filter} on_change="filter" />
            </div>
            <div style="width: 1px; height: 20px; background: var(--ccem-border);"></div>
            <div style="display: flex; align-items: center; gap: 8px;">
              <span style="font-size: 11px; color: var(--ccem-fg-muted); text-transform: uppercase; letter-spacing: 0.05em;">Namespace</span>
              <.segmented_control options={["all", "web", "api", "service", "tool"]} active={@namespace_filter} on_change="namespace_filter" />
            </div>
          </div>
        </.card>

        <%!-- Projects grid + Port Ranges side panel --%>
        <div style="display: flex; gap: 16px;">
          <div style="flex: 1; min-width: 0;">
            <div :if={@filtered == []} style="text-align: center; padding: 48px 0; color: var(--ccem-fg-muted);">
              No projects match filters
            </div>
            <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 12px;">
              <.card :for={p <- @filtered} style="padding: 16px;">
                <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px;">
                  <span style="font-size: 13px; font-weight: 600; color: var(--ccem-fg); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"><%= p.name %></span>
                  <.badge tone={ns_tone(to_string(p.namespace))} square={true}><%= p.namespace %></.badge>
                </div>
                <div style="display: flex; align-items: center; gap: 10px; margin-bottom: 12px;">
                  <span style="font-size: 24px; font-family: monospace; font-weight: 700; color: var(--ccem-fg);">:<%= p.port %></span>
                  <.badge tone={if p.active, do: "success", else: "neutral"} dot={true}><%= if p.active, do: "active", else: "inactive" %></.badge>
                </div>
                <div :if={MapSet.member?(@clash_ports, p.name)} style="padding: 8px; border-radius: 6px; background: var(--ccem-err-bg, rgba(239,68,68,0.08)); border: 1px solid var(--ccem-err-border, rgba(239,68,68,0.2)); display: flex; align-items: center; justify-content: space-between;">
                  <.badge tone="error">Port clash</.badge>
                  <.btn variant="destructive" size="xs" phx-click="assign_port" phx-value-project={p.name}>Reassign</.btn>
                </div>
              </.card>
            </div>
          </div>

          <%!-- Port Ranges panel --%>
          <div style="width: 240px; flex-shrink: 0;">
            <.card style="padding: 16px;">
              <h3 style="font-size: 12px; font-weight: 600; color: var(--ccem-fg-muted); margin: 0 0 16px 0;">Port Ranges</h3>
              <div style="display: flex; flex-direction: column; gap: 12px;">
                <div :for={{ns, range} <- @port_ranges} style="display: flex; flex-direction: column; gap: 4px;">
                  <div style="display: flex; justify-content: space-between; font-size: 11px;">
                    <span style="color: var(--ccem-fg-muted); text-transform: capitalize;"><%= ns %></span>
                    <span style="color: var(--ccem-fg-subtle); font-family: monospace;"><%= range.first %>-<%= range.last %></span>
                  </div>
                  <div style="height: 6px; background: var(--ccem-surface-2); border-radius: 3px; overflow: hidden;">
                    <div style={"height: 100%; border-radius: 3px; background: var(--ccem-accent); width: #{min(trunc(Range.size(range) / 70 * 100), 100)}%;"}></div>
                  </div>
                </div>
              </div>
            </.card>
          </div>
        </div>

        <%!-- Clash resolution --%>
        <div :if={@clash_count > 0} style="margin-top: 16px;">
          <.card style="border-color: var(--ccem-err-border, rgba(239,68,68,0.3)); padding: 16px;">
            <h3 style="font-size: 13px; font-weight: 600; color: var(--ccem-err, #ef4444); margin: 0 0 12px 0;">Clash Resolution</h3>
            <div style="display: flex; flex-direction: column; gap: 8px;">
              <div :for={clash <- @clashes} style="display: flex; align-items: center; justify-content: space-between; padding: 10px 12px; background: var(--ccem-surface-1); border-radius: 6px; border: 1px solid var(--ccem-border);">
                <div style="font-size: 13px; display: flex; align-items: center; gap: 8px;">
                  <span style="color: var(--ccem-fg-muted);">Port</span>
                  <span style="font-family: monospace; font-weight: 700; color: var(--ccem-fg);"><%= clash.port %></span>
                  <.badge tone="error"><%= Enum.join(clash.projects, ", ") %></.badge>
                </div>
              </div>
            </div>
          </.card>
        </div>
      </:main>
    </.page_layout>
    """
  end
end
