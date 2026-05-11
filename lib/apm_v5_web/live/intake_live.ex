defmodule ApmV5Web.IntakeLive do
  @moduledoc """
  LiveView for the Intake monitoring dashboard at /intake.

  Displays incoming request records, watcher status, and dispatcher
  activity from the Intake subsystem.
  """

  use ApmV5Web, :live_view

  alias ApmV5.Intake.Store, as: IntakeStore

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "intake:events")
    end

    events = IntakeStore.list(limit: 50)
    watchers = IntakeStore.watchers()

    socket =
      socket
      |> assign(:page_title, "Intake")
      |> assign(:events, events)
      |> assign(:watchers, watchers)
      |> assign(:filter_source, "all")
      |> assign(:filter_type, "all")
      |> assign(:sidebar_collapsed, false)
      |> assign(:inspector_open, false)
      |> assign(:selected_event, nil)

    {:ok, ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data(socket)}
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

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_collapsed: !socket.assigns.sidebar_collapsed)}
  end

  def handle_event("select_event", %{"id" => id}, socket) do
    selected = Enum.find(socket.assigns.events, fn e -> Map.get(e, :id) == id end)

    {:noreply,
     socket
     |> assign(:selected_event, selected)
     |> assign(:inspector_open, selected != nil)}
  end

  def handle_event("close_inspector", _params, socket) do
    {:noreply, socket |> assign(:inspector_open, false) |> assign(:selected_event, nil)}
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp severity_tone("critical"), do: "err"
  defp severity_tone("major"), do: "warn"
  defp severity_tone("success"), do: "ok"
  defp severity_tone(_), do: "neutral"

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
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar><.sidebar_nav current_path="/intake" /></:sidebar>
      <:topbar><.top_bar project_name="CCEM APM" /></:topbar>
      <:main>
        <div style="padding: var(--ccem-space-4); display: flex; flex-direction: column; gap: var(--ccem-space-4);">

          <%!-- Page header --%>
          <div style="display: flex; align-items: center; justify-content: space-between;">
            <div style="display: flex; align-items: center; gap: var(--ccem-space-3);">
              <h1 style="font-size: var(--ccem-text-lg); font-weight: 600; color: var(--ccem-fg-primary);">
                Intake Event Stream
              </h1>
              <.badge tone="neutral"><%= length(@events) %> events</.badge>
            </div>
            <div style="display: flex; align-items: center; gap: var(--ccem-space-2);">
              <span style="font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted);">Source:</span>
              <select phx-change="filter_source" name="source"
                style="background: var(--ccem-surface-2); color: var(--ccem-fg-primary); border: 1px solid var(--ccem-border); border-radius: var(--ccem-radius-sm); padding: 0 var(--ccem-space-2); height: 28px; font-size: var(--ccem-text-xs);">
                <option value="all" selected={@filter_source == "all"}>All</option>
                <%= for {source, _count} <- source_counts(@events) do %>
                  <option value={source} selected={@filter_source == source}><%= source %></option>
                <% end %>
              </select>
              <span style="font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted);">Type:</span>
              <select phx-change="filter_type" name="type"
                style="background: var(--ccem-surface-2); color: var(--ccem-fg-primary); border: 1px solid var(--ccem-border); border-radius: var(--ccem-radius-sm); padding: 0 var(--ccem-space-2); height: 28px; font-size: var(--ccem-text-xs);">
                <option value="all" selected={@filter_type == "all"}>All</option>
                <option value="context_fetch" selected={@filter_type == "context_fetch"}>context_fetch</option>
                <option value="submission" selected={@filter_type == "submission"}>submission</option>
                <option value="sync_complete" selected={@filter_type == "sync_complete"}>sync_complete</option>
                <option value="custom" selected={@filter_type == "custom"}>custom</option>
              </select>
            </div>
          </div>

          <%!-- Stats row --%>
          <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: var(--ccem-space-3);">
            <.stat_tile label="Total Events" value={to_string(length(@events))} delta_direction="flat" />
            <%= for {source, count} <- Enum.take(source_counts(@events), 3) do %>
              <.stat_tile label={source} value={to_string(count)} delta_direction="flat" />
            <% end %>
          </div>

          <%!-- Watcher registry --%>
          <.card padded={true}>
            <div style="display: flex; align-items: center; gap: var(--ccem-space-2); margin-bottom: var(--ccem-space-3);">
              <.icon name="hero-eye" class="size-4 text-accent" />
              <span style="font-size: var(--ccem-text-sm); font-weight: 600; color: var(--ccem-fg-primary);">
                Registered Watchers
              </span>
              <.badge tone="accent" square={true}><%= length(@watchers) %></.badge>
            </div>
            <div style="display: flex; flex-wrap: wrap; gap: var(--ccem-space-2);">
              <%= for watcher <- @watchers do %>
                <div style="display: flex; align-items: center; gap: var(--ccem-space-2); background: var(--ccem-surface-3); border-radius: var(--ccem-radius-sm); padding: var(--ccem-space-1) var(--ccem-space-3);">
                  <.badge tone="ok" dot={true} square={true}> </.badge>
                  <span style="font-family: var(--ccem-font-mono); font-size: var(--ccem-text-xs); color: var(--ccem-fg-secondary);">
                    <%= watcher.name() %>
                  </span>
                  <span style="font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted);">
                    <%= if watcher.sources() == [:all], do: "all sources", else: Enum.join(watcher.sources(), ", ") %>
                  </span>
                </div>
              <% end %>
            </div>
          </.card>

          <%!-- Event stream table --%>
          <.card padded={false}>
            <div style="padding: var(--ccem-space-3) var(--ccem-space-4); border-bottom: 1px solid var(--ccem-border); display: flex; align-items: center; justify-content: space-between;">
              <span style="font-size: var(--ccem-text-sm); font-weight: 600; color: var(--ccem-fg-primary);">
                Event Stream
              </span>
              <span style="font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted);">
                Live — updates in real-time
              </span>
            </div>
            <%= if @events == [] do %>
              <div style="display: flex; flex-direction: column; align-items: center; justify-content: center; padding: var(--ccem-space-12); gap: var(--ccem-space-2); color: var(--ccem-fg-muted);">
                <.icon name="hero-inbox" class="size-8 opacity-30" />
                <span style="font-size: var(--ccem-text-sm);">
                  No events yet. POST to
                  <code style="font-family: var(--ccem-font-mono); font-size: var(--ccem-text-xs); background: var(--ccem-surface-3); padding: 0 4px; border-radius: 3px;">/api/intake</code>
                  to submit one.
                </span>
              </div>
            <% else %>
              <.data_table id="intake-events" rows={@events}>
                <:col :let={event} label="Time">
                  <span style="font-family: var(--ccem-font-mono); font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted);">
                    <%= format_time(event.received_at) %>
                  </span>
                </:col>
                <:col :let={event} label="Source">
                  <.badge tone="neutral"><%= event.source %></.badge>
                </:col>
                <:col :let={event} label="Type">
                  <span style="font-family: var(--ccem-font-mono); font-size: var(--ccem-text-xs); color: var(--ccem-fg-secondary);">
                    <%= event.event_type %>
                  </span>
                </:col>
                <:col :let={event} label="Severity">
                  <.badge tone={severity_tone(event.severity)}><%= event.severity %></.badge>
                </:col>
                <:col :let={event} label="Project">
                  <span style="font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted);">
                    <%= event.project %>
                  </span>
                </:col>
                <:col :let={event} label="Payload">
                  <span style="font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted); max-width: 20rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; display: block;">
                    <%= event.payload["title"] || event.payload["message"] || inspect(event.payload) |> String.slice(0, 60) %>
                  </span>
                </:col>
                <:col :let={event} label="ID">
                  <span style="font-family: var(--ccem-font-mono); font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted);">
                    <%= String.slice(event.id, 0, 8) %>…
                  </span>
                </:col>
                <:col :let={event} label="">
                  <.btn variant="ghost" size="xs" phx-click="select_event" phx-value-id={event.id}>
                    View
                  </.btn>
                </:col>
              </.data_table>
            <% end %>
          </.card>

        </div>
      </:main>
      <:inspector>
        <%= if @selected_event do %>
          <div style="padding: var(--ccem-space-4); display: flex; flex-direction: column; gap: var(--ccem-space-3);">
            <div style="display: flex; align-items: center; justify-content: space-between;">
              <span style="font-size: var(--ccem-text-sm); font-weight: 600; color: var(--ccem-fg-primary);">Event Detail</span>
              <.btn variant="ghost" size="xs" phx-click="close_inspector">Close</.btn>
            </div>
            <div style="font-family: var(--ccem-font-mono); font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted); word-break: break-all;">
              <div><strong>ID:</strong> <%= @selected_event.id %></div>
              <div><strong>Source:</strong> <%= @selected_event.source %></div>
              <div><strong>Type:</strong> <%= @selected_event.event_type %></div>
              <div><strong>Severity:</strong> <%= @selected_event.severity %></div>
              <div><strong>Project:</strong> <%= @selected_event.project %></div>
              <div><strong>Received:</strong> <%= format_time(@selected_event.received_at) %></div>
            </div>
            <div>
              <span style="font-size: var(--ccem-text-xs); font-weight: 600; color: var(--ccem-fg-secondary);">Payload</span>
              <pre style="background: var(--ccem-surface-3); border-radius: var(--ccem-radius-sm); padding: var(--ccem-space-2); font-family: var(--ccem-font-mono); font-size: var(--ccem-text-xs); color: var(--ccem-fg-secondary); overflow-x: auto; margin-top: var(--ccem-space-2);"><%= inspect(@selected_event.payload, pretty: true) %></pre>
            </div>
          </div>
        <% end %>
      </:inspector>
    </.page_layout>
    """
  end
end
