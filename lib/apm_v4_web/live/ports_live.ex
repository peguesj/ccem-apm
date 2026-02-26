defmodule ApmV4Web.PortsLive do
  use ApmV4Web, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:ports")
    end

    port_map = ApmV4.PortManager.get_port_map()
    clashes = ApmV4.PortManager.detect_clashes()
    ranges = ApmV4.PortManager.get_port_ranges()

    {:ok,
     socket
     |> assign(:page_title, "Ports")
     |> assign(:port_map, port_map)
     |> assign(:clashes, clashes)
     |> assign(:port_ranges, ranges)
     |> assign(:status_filter, "all")
     |> assign(:namespace_filter, "all")
     |> assign_derived(port_map, clashes)}
  end

  @impl true
  def handle_event("scan_ports", _params, socket) do
    ApmV4.PortManager.scan_active_ports()
    port_map = ApmV4.PortManager.get_port_map()
    clashes = ApmV4.PortManager.detect_clashes()

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
    case ApmV4.PortManager.assign_port(project) do
      {:ok, _port} ->
        port_map = ApmV4.PortManager.get_port_map()
        clashes = ApmV4.PortManager.detect_clashes()
        {:noreply, socket |> assign(:port_map, port_map) |> assign(:clashes, clashes) |> assign_derived(port_map, clashes)}
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No available port")}
    end
  end

  @impl true
  def handle_info({:port_assigned, _, _}, socket) do
    port_map = ApmV4.PortManager.get_port_map()
    clashes = ApmV4.PortManager.detect_clashes()
    {:noreply, socket |> assign(:port_map, port_map) |> assign(:clashes, clashes) |> assign_derived(port_map, clashes)}
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

  defp ns_color("web"), do: "bg-blue-500/20 text-blue-400 border-blue-500/30"
  defp ns_color("api"), do: "bg-purple-500/20 text-purple-400 border-purple-500/30"
  defp ns_color("service"), do: "bg-amber-500/20 text-amber-400 border-amber-500/30"
  defp ns_color("tool"), do: "bg-emerald-500/20 text-emerald-400 border-emerald-500/30"
  defp ns_color(_), do: "bg-zinc-500/20 text-zinc-400 border-zinc-500/30"

  defp range_color(:web), do: "bg-blue-500"
  defp range_color(:api), do: "bg-purple-500"
  defp range_color(:service), do: "bg-amber-500"
  defp range_color(:tool), do: "bg-emerald-500"
  defp range_color(_), do: "bg-zinc-600"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold text-zinc-100">Port Manager</h1>
          <p class="text-sm text-zinc-500 mt-1">Port assignments across CCEM projects</p>
        </div>
        <div class="flex items-center gap-3">
          <span class="px-3 py-1 rounded-full text-xs font-medium bg-zinc-800 text-zinc-300 border border-zinc-700">
            <%= @total %> projects
          </span>
          <span class="px-3 py-1 rounded-full text-xs font-medium bg-emerald-500/20 text-emerald-400 border border-emerald-500/30">
            <%= @active_count %> active
          </span>
          <span :if={@clash_count > 0} class="px-3 py-1 rounded-full text-xs font-medium bg-red-500/20 text-red-400 border border-red-500/30">
            <%= @clash_count %> clashes
          </span>
          <button phx-click="scan_ports" class="px-4 py-2 rounded-lg text-sm font-medium bg-emerald-600 hover:bg-emerald-500 text-white transition-colors">
            Scan Ports
          </button>
        </div>
      </div>

      <div class="flex items-center gap-4 p-3 bg-zinc-900 rounded-lg border border-zinc-800">
        <span class="text-xs text-zinc-500 uppercase tracking-wider">Status</span>
        <div class="flex gap-1">
          <button :for={s <- ["all", "active", "clashes"]} phx-click="filter" phx-value-status={s}
            class={["px-3 py-1 rounded text-xs font-medium transition-colors",
              if(@status_filter == s, do: "bg-zinc-700 text-zinc-100", else: "text-zinc-500 hover:text-zinc-300")]}>
            <%= String.capitalize(s) %>
          </button>
        </div>
        <div class="w-px h-4 bg-zinc-700"></div>
        <span class="text-xs text-zinc-500 uppercase tracking-wider">Namespace</span>
        <div class="flex gap-1">
          <button :for={ns <- ["all", "web", "api", "service", "tool"]} phx-click="namespace_filter" phx-value-namespace={ns}
            class={["px-3 py-1 rounded text-xs font-medium transition-colors",
              if(@namespace_filter == ns, do: "bg-zinc-700 text-zinc-100", else: "text-zinc-500 hover:text-zinc-300")]}>
            <%= String.capitalize(ns) %>
          </button>
        </div>
      </div>

      <div class="flex gap-6">
        <div class="flex-1">
          <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
            <div :for={p <- @filtered} class="bg-zinc-900 rounded-lg border border-zinc-800 p-4 hover:border-zinc-700 transition-colors">
              <div class="flex items-center justify-between mb-3">
                <h3 class="text-sm font-semibold text-zinc-200 truncate"><%= p.name %></h3>
                <span class={["px-2 py-0.5 rounded text-[10px] font-medium border", ns_color(to_string(p.namespace))]}>
                  <%= p.namespace %>
                </span>
              </div>
              <div class="flex items-center gap-3 mb-3">
                <span class="text-3xl font-mono font-bold text-zinc-100">:<%= p.port %></span>
                <span class={["w-2.5 h-2.5 rounded-full", if(p.active, do: "bg-emerald-400", else: "bg-zinc-600")]}></span>
              </div>
              <div :if={MapSet.member?(@clash_ports, p.name)} class="p-2 rounded bg-red-500/10 border border-red-500/20">
                <span class="text-xs text-red-400">Port clash</span>
                <button phx-click="assign_port" phx-value-project={p.name}
                  class="ml-2 px-2 py-1 rounded text-[10px] font-medium bg-red-600 hover:bg-red-500 text-white">
                  Reassign
                </button>
              </div>
            </div>
          </div>
          <div :if={@filtered == []} class="text-center py-12 text-zinc-600">No projects match filters</div>
        </div>

        <div class="w-64 shrink-0">
          <div class="bg-zinc-900 rounded-lg border border-zinc-800 p-4">
            <h3 class="text-sm font-semibold text-zinc-300 mb-4">Port Ranges</h3>
            <div class="space-y-3">
              <div :for={{ns, range} <- @port_ranges} class="space-y-1">
                <div class="flex items-center justify-between text-xs">
                  <span class="text-zinc-400 capitalize"><%= ns %></span>
                  <span class="text-zinc-600 font-mono"><%= range.first %>-<%= range.last %></span>
                </div>
                <div class="h-2 bg-zinc-800 rounded-full overflow-hidden">
                  <div class={["h-full rounded-full", range_color(ns)]} style={"width: #{min(Range.size(range) / 70, 100)}%"}></div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div :if={@clash_count > 0} class="bg-red-500/5 rounded-lg border border-red-500/20 p-4">
        <h3 class="text-sm font-semibold text-red-400 mb-3">Clash Resolution</h3>
        <div class="space-y-2">
          <div :for={clash <- @clashes} class="flex items-center justify-between p-3 bg-zinc-900 rounded border border-zinc-800">
            <div class="text-sm">
              <span class="text-zinc-400">Port</span>
              <span class="font-mono font-bold text-zinc-200 mx-2"><%= clash.port %></span>
              <span class="text-red-400"><%= Enum.join(clash.projects, ", ") %></span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
