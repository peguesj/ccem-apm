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

  defp ns_color("web"), do: "bg-blue-500/20 text-blue-400 border-blue-500/30"
  defp ns_color("api"), do: "bg-purple-500/20 text-purple-400 border-purple-500/30"
  defp ns_color("service"), do: "bg-amber-500/20 text-amber-400 border-amber-500/30"
  defp ns_color("tool"), do: "bg-emerald-500/20 text-emerald-400 border-emerald-500/30"
  defp ns_color(_), do: "bg-base-content/10 text-base-content/60 border-base-content/20"

  defp range_color(:web), do: "bg-blue-500"
  defp range_color(:api), do: "bg-purple-500"
  defp range_color(:service), do: "bg-amber-500"
  defp range_color(:tool), do: "bg-emerald-500"
  defp range_color(_), do: "bg-base-content/30"

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
          <.nav_item icon="hero-clock" label="Timeline" active={false} href="/timeline" />
          <.nav_item icon="hero-bell" label="Notifications" active={false} href="/notifications" />
          <.nav_item icon="hero-queue-list" label="Background Tasks" active={false} href="/tasks" />
          <.nav_item icon="hero-magnifying-glass" label="Project Scanner" active={false} href="/scanner" />
          <.nav_item icon="hero-bolt" label="Actions" active={false} href="/actions" />
          <.nav_item icon="hero-sparkles" label="Skills" active={false} href="/skills" />
          <.nav_item icon="hero-arrow-path" label="Ralph" active={false} href="/ralph" />
          <.nav_item icon="hero-signal" label="Ports" active={true} href="/ports" />
          <.nav_item icon="hero-book-open" label="Docs" active={false} href="/docs" />
        </nav>
      </aside>

      <%!-- Main content --%>
      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Top bar --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Port Manager</h2>
            <div class="badge badge-sm badge-ghost"><%= @total %> projects</div>
            <div class="badge badge-sm badge-success"><%= @active_count %> active</div>
            <div :if={@clash_count > 0} class="badge badge-sm badge-error"><%= @clash_count %> clashes</div>
          </div>
          <button phx-click="scan_ports" class="btn btn-primary btn-xs">
            <.icon name="hero-magnifying-glass" class="size-3" /> Scan Ports
          </button>
        </header>

        <%!-- Content --%>
        <div class="flex-1 overflow-y-auto p-4 space-y-4">
          <%!-- Filters --%>
          <div class="flex items-center gap-4 bg-base-200 rounded-xl border border-base-300 p-3">
            <span class="text-xs text-base-content/50 uppercase tracking-wider">Status</span>
            <div class="flex gap-1">
              <button :for={s <- ["all", "active", "clashes"]} phx-click="filter" phx-value-status={s}
                class={["btn btn-xs", if(@status_filter == s, do: "btn-primary", else: "btn-ghost")]}>
                <%= String.capitalize(s) %>
              </button>
            </div>
            <div class="w-px h-4 bg-base-300"></div>
            <span class="text-xs text-base-content/50 uppercase tracking-wider">Namespace</span>
            <div class="flex gap-1">
              <button :for={ns <- ["all", "web", "api", "service", "tool"]} phx-click="namespace_filter" phx-value-namespace={ns}
                class={["btn btn-xs", if(@namespace_filter == ns, do: "btn-primary", else: "btn-ghost")]}>
                <%= String.capitalize(ns) %>
              </button>
            </div>
          </div>

          <%!-- Projects + Port Ranges --%>
          <div class="flex gap-4">
            <div class="flex-1">
              <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
                <div :for={p <- @filtered} class="bg-base-200 rounded-xl border border-base-300 p-4 hover:border-primary/30 transition-colors">
                  <div class="flex items-center justify-between mb-3">
                    <h3 class="text-sm font-semibold text-base-content truncate"><%= p.name %></h3>
                    <span class={"px-2 py-0.5 rounded text-[10px] font-medium border #{ns_color(to_string(p.namespace))}"}>
                      <%= p.namespace %>
                    </span>
                  </div>
                  <div class="flex items-center gap-3 mb-3">
                    <span class="text-3xl font-mono font-bold text-base-content">:<%= p.port %></span>
                    <span class={["w-2.5 h-2.5 rounded-full", if(p.active, do: "bg-success", else: "bg-base-content/20")]}></span>
                  </div>
                  <div :if={MapSet.member?(@clash_ports, p.name)} class="p-2 rounded bg-error/10 border border-error/20">
                    <span class="text-xs text-error">Port clash</span>
                    <button phx-click="assign_port" phx-value-project={p.name} class="ml-2 btn btn-xs btn-error">
                      Reassign
                    </button>
                  </div>
                </div>
              </div>
              <div :if={@filtered == []} class="text-center py-12 text-base-content/30">No projects match filters</div>
            </div>

            <div class="w-64 shrink-0">
              <div class="bg-base-200 rounded-xl border border-base-300 p-4">
                <h3 class="text-sm font-semibold text-base-content/80 mb-4">Port Ranges</h3>
                <div class="space-y-3">
                  <div :for={{ns, range} <- @port_ranges} class="space-y-1">
                    <div class="flex items-center justify-between text-xs">
                      <span class="text-base-content/60 capitalize"><%= ns %></span>
                      <span class="text-base-content/40 font-mono"><%= range.first %>-<%= range.last %></span>
                    </div>
                    <div class="h-2 bg-base-300 rounded-full overflow-hidden">
                      <div class={["h-full rounded-full", range_color(ns)]} style={"width: #{min(Range.size(range) / 70, 100)}%"}></div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <%!-- Clash resolution --%>
          <div :if={@clash_count > 0} class="bg-error/5 rounded-xl border border-error/20 p-4">
            <h3 class="text-sm font-semibold text-error mb-3">Clash Resolution</h3>
            <div class="space-y-2">
              <div :for={clash <- @clashes} class="flex items-center justify-between p-3 bg-base-200 rounded-lg border border-base-300">
                <div class="text-sm">
                  <span class="text-base-content/60">Port</span>
                  <span class="font-mono font-bold text-base-content mx-2"><%= clash.port %></span>
                  <span class="text-error"><%= Enum.join(clash.projects, ", ") %></span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
