defmodule ApmV5Web.IntakeLive do
  use ApmV5Web, :live_view

  alias ApmV5.Intake.Store, as: IntakeStore

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "intake:events")
    end

    events = IntakeStore.list(limit: 50)
    watchers = IntakeStore.watchers()

    {:ok,
     socket
     |> assign(:page_title, "Intake")
     |> assign(:events, events)
     |> assign(:watchers, watchers)
     |> assign(:filter_source, "all")
     |> assign(:filter_type, "all")}
  end

  @impl true
  def handle_info({:intake_event, event}, socket) do
    events = [event | Enum.take(socket.assigns.events, 49)]
    {:noreply, assign(socket, :events, events)}
  end

  @impl true
  def handle_event("filter_source", %{"source" => source}, socket) do
    source_val = if source == "all", do: nil, else: source
    events = IntakeStore.list(limit: 50, source: source_val)
    {:noreply, socket |> assign(:filter_source, source) |> assign(:events, events)}
  end

  def handle_event("filter_type", %{"type" => type}, socket) do
    type_val = if type == "all", do: nil, else: type
    source_val = if socket.assigns.filter_source == "all", do: nil, else: socket.assigns.filter_source
    events = IntakeStore.list(limit: 50, source: source_val, event_type: type_val)
    {:noreply, socket |> assign(:filter_type, type) |> assign(:events, events)}
  end

  # ── Components ───────────────────────────────────────────────────────────

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

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp severity_badge_class("critical"), do: "badge badge-xs badge-error"
  defp severity_badge_class("major"), do: "badge badge-xs badge-warning"
  defp severity_badge_class("success"), do: "badge badge-xs badge-success"
  defp severity_badge_class(_), do: "badge badge-xs badge-ghost"

  defp source_counts(events) do
    events
    |> Enum.group_by(& &1.source)
    |> Enum.map(fn {source, evts} -> {source, length(evts)} end)
    |> Enum.sort_by(fn {_, count} -> count end, :desc)
  end

  defp format_time(dt) do
    Calendar.strftime(dt, "%H:%M:%S")
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
          <.nav_item icon="hero-clock" label="Timeline" active={false} href="/timeline" />
          <.nav_item icon="hero-bell" label="Notifications" active={false} href="/notifications" />
          <.nav_item icon="hero-queue-list" label="Background Tasks" active={false} href="/tasks" />
          <.nav_item icon="hero-inbox-arrow-down" label="Intake" active={true} href="/intake" />
          <.nav_item icon="hero-magnifying-glass" label="Project Scanner" active={false} href="/scanner" />
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
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Intake Event Stream</h2>
            <div class="badge badge-sm badge-ghost"><%= length(@events) %> events</div>
          </div>
          <div class="flex items-center gap-2">
            <span class="text-xs text-base-content/40">Source:</span>
            <select phx-change="filter_source" name="source" class="select select-xs select-ghost">
              <option value="all" selected={@filter_source == "all"}>All</option>
              <%= for {source, _count} <- source_counts(@events) do %>
                <option value={source} selected={@filter_source == source}><%= source %></option>
              <% end %>
            </select>
            <span class="text-xs text-base-content/40">Type:</span>
            <select phx-change="filter_type" name="type" class="select select-xs select-ghost">
              <option value="all" selected={@filter_type == "all"}>All</option>
              <option value="context_fetch" selected={@filter_type == "context_fetch"}>context_fetch</option>
              <option value="submission" selected={@filter_type == "submission"}>submission</option>
              <option value="sync_complete" selected={@filter_type == "sync_complete"}>sync_complete</option>
              <option value="custom" selected={@filter_type == "custom"}>custom</option>
            </select>
          </div>
        </header>

        <%!-- Body --%>
        <div class="flex-1 overflow-auto p-4 space-y-4">

          <%!-- Stats row --%>
          <div class="grid grid-cols-4 gap-3">
            <div class="bg-base-200 rounded-lg p-3">
              <div class="text-2xl font-bold text-base-content"><%= length(@events) %></div>
              <div class="text-xs text-base-content/50 mt-1">Total Events</div>
            </div>
            <%= for {source, count} <- Enum.take(source_counts(@events), 3) do %>
              <div class="bg-base-200 rounded-lg p-3">
                <div class="text-2xl font-bold text-primary"><%= count %></div>
                <div class="text-xs text-base-content/50 mt-1"><%= source %></div>
              </div>
            <% end %>
          </div>

          <%!-- Watcher registry --%>
          <div class="bg-base-200 rounded-lg p-4">
            <h3 class="text-sm font-semibold text-base-content mb-3 flex items-center gap-2">
              <.icon name="hero-eye" class="size-4 text-primary" />
              Registered Watchers
              <span class="badge badge-xs badge-primary"><%= length(@watchers) %></span>
            </h3>
            <div class="flex flex-wrap gap-2">
              <%= for watcher <- @watchers do %>
                <div class="flex items-center gap-2 bg-base-300 rounded px-3 py-1.5">
                  <span class="inline-block w-1.5 h-1.5 rounded-full bg-success"></span>
                  <span class="text-xs font-mono text-base-content/80"><%= watcher.name() %></span>
                  <span class="text-xs text-base-content/40">
                    <%= if watcher.sources() == [:all], do: "all sources", else: Enum.join(watcher.sources(), ", ") %>
                  </span>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Event stream table --%>
          <div class="bg-base-200 rounded-lg overflow-hidden">
            <div class="px-4 py-3 border-b border-base-300 flex items-center justify-between">
              <h3 class="text-sm font-semibold text-base-content">Event Stream</h3>
              <span class="text-xs text-base-content/40">Live — updates in real-time</span>
            </div>
            <div class="overflow-auto">
              <table class="w-full text-sm">
                <thead>
                  <tr class="text-left text-base-content/50 border-b border-base-300 bg-base-300/30">
                    <th class="pb-2 pt-2 px-4">Time</th>
                    <th class="pb-2 pt-2 px-4">Source</th>
                    <th class="pb-2 pt-2 px-4">Type</th>
                    <th class="pb-2 pt-2 px-4">Severity</th>
                    <th class="pb-2 pt-2 px-4">Project</th>
                    <th class="pb-2 pt-2 px-4">Payload Summary</th>
                    <th class="pb-2 pt-2 px-4">ID</th>
                  </tr>
                </thead>
                <tbody>
                  <%= if @events == [] do %>
                    <tr>
                      <td colspan="7" class="py-12 text-center text-base-content/40">
                        <div class="flex flex-col items-center gap-2">
                          <.icon name="hero-inbox" class="size-8 opacity-30" />
                          <span>No events yet. POST to <code class="text-xs bg-base-300 px-1 rounded">/api/intake</code> to submit one.</span>
                        </div>
                      </td>
                    </tr>
                  <% else %>
                    <%= for event <- @events do %>
                      <tr class="border-b border-base-300/50 hover:bg-base-300/30">
                        <td class="py-2 px-4 font-mono text-xs text-base-content/60">
                          <%= format_time(event.received_at) %>
                        </td>
                        <td class="py-2 px-4">
                          <span class="badge badge-xs badge-outline"><%= event.source %></span>
                        </td>
                        <td class="py-2 px-4 text-xs font-mono text-base-content/80"><%= event.event_type %></td>
                        <td class="py-2 px-4">
                          <span class={severity_badge_class(event.severity)}><%= event.severity %></span>
                        </td>
                        <td class="py-2 px-4 text-xs text-base-content/60"><%= event.project %></td>
                        <td class="py-2 px-4 text-xs text-base-content/50 max-w-xs truncate">
                          <%= event.payload["title"] || event.payload["message"] || inspect(event.payload) |> String.slice(0, 60) %>
                        </td>
                        <td class="py-2 px-4 font-mono text-xs text-base-content/30">
                          <%= String.slice(event.id, 0, 8) %>…
                        </td>
                      </tr>
                    <% end %>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>

        </div>
      </div>
    </div>
    """
  end
end
