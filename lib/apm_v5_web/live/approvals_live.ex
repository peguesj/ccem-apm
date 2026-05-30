defmodule ApmV5Web.ApprovalsLive do
  @moduledoc """
  Govern — Approvals LiveView (CP-190 / US-465 / CCEM-524).

  Displays the active approval queue with pending decisions, countdown timers,
  and approve/deny controls. Uses CCEM Design System exclusively.

  Route: /approvals

  ## Features
  - Live approval queue via PubSub "agentlock:approval"
  - Pending decision table with countdown timers
  - Approve/deny/defer actions per pending item
  - Stat tiles: pending count, approved today, denied today
  """

  use ApmV5Web, :live_view

  alias ApmV5.Auth.{ApprovalQueue, ApprovalAuditLog}

  @refresh_ms 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "agentlock:approval")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "agentlock:audit")
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    {:ok,
     socket
     |> assign(:page_title, "Approvals")
     |> assign(:sidebar_collapsed, false)
     |> assign(:inspector_open, false)
     |> assign(:selected_item, nil)
     |> load_data()
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load_data(socket)}
  end

  def handle_info({:approval_pending, _item}, socket), do: {:noreply, load_data(socket)}
  def handle_info({:approval_decided, _item}, socket), do: {:noreply, load_data(socket)}
  def handle_info({:audit_entry_added, _entry}, socket), do: {:noreply, load_data(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("approve", %{"id" => id}, socket) do
    catch_exit(fn -> apply(ApprovalQueue, :approve, [id, %{approver: "dashboard"}]) end)
    {:noreply, load_data(socket)}
  end

  def handle_event("deny", %{"id" => id}, socket) do
    catch_exit(fn -> apply(ApprovalQueue, :deny, [id, "Denied via Approvals dashboard"]) end)
    {:noreply, load_data(socket)}
  end

  def handle_event("defer", %{"id" => id}, socket) do
    catch_exit(fn -> apply(ApprovalQueue, :defer, [id, "Deferred via dashboard"]) end)
    {:noreply, load_data(socket)}
  end

  def handle_event("select_item", %{"id" => id}, socket) do
    item =
      socket.assigns.pending_items
      |> Enum.find(&(to_string(Map.get(&1, :id, "")) == id))

    {:noreply, socket |> assign(:selected_item, item) |> assign(:inspector_open, item != nil)}
  end

  def handle_event("close_inspector", _params, socket) do
    {:noreply, socket |> assign(:selected_item, nil) |> assign(:inspector_open, false)}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_collapsed, !socket.assigns.sidebar_collapsed)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav current_path="/approvals" />
      </:sidebar>
      <:topbar>
        <.top_bar project_name="CCEM APM" />
      </:topbar>
      <:main>
        <div style="padding: 24px; display: flex; flex-direction: column; gap: 24px;">

          <!-- Stat tiles -->
          <div style="display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px;">
            <.card>
              <.stat_tile
                label="Pending Approvals"
                value={to_string(@pending_count)}
                delta_direction={if @pending_count > 0, do: "down", else: "flat"}
              />
            </.card>
            <.card>
              <.stat_tile
                label="Approved Today"
                value={to_string(@approved_today)}
                delta_direction="up"
              />
            </.card>
            <.card>
              <.stat_tile
                label="Denied Today"
                value={to_string(@denied_today)}
                delta_direction="flat"
              />
            </.card>
          </div>

          <!-- Pending approvals table -->
          <.card padded={false}>
            <div style="padding: 16px 16px 0 16px; display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px;">
              <span style="font-size: 13px; font-weight: 600; color: var(--ccem-fg);">Pending Decisions</span>
              <.badge tone={if @pending_count > 0, do: "warning", else: "neutral"}>
                {@pending_count}
              </.badge>
            </div>
            <.data_table id="approvals-table" rows={@pending_items}>
              <:col :let={item} label="Agent">{Map.get(item, :agent_id, "—")}</:col>
              <:col :let={item} label="Tool">{Map.get(item, :tool_name, "—")}</:col>
              <:col :let={item} label="Risk">
                <.badge tone={risk_tone(Map.get(item, :risk_level, :low))}>
                  {Map.get(item, :risk_level, "—")}
                </.badge>
              </:col>
              <:col :let={item} label="TTL">
                <span style="font-family: var(--ccem-font-mono); font-size: 12px; color: var(--ccem-warn);">
                  {format_ttl(Map.get(item, :expires_at))}
                </span>
              </:col>
              <:col :let={item} label="Actions">
                <div style="display: flex; gap: 6px;">
                  <.btn variant="primary" size="xs" phx-click="approve" phx-value-id={Map.get(item, :id, "")}>
                    Approve
                  </.btn>
                  <.btn variant="destructive" size="xs" phx-click="deny" phx-value-id={Map.get(item, :id, "")}>
                    Deny
                  </.btn>
                  <.btn variant="ghost" size="xs" phx-click="defer" phx-value-id={Map.get(item, :id, "")}>
                    Defer
                  </.btn>
                </div>
              </:col>
            </.data_table>
            <%= if @pending_items == [] do %>
              <div style="padding: 40px; text-align: center; color: var(--ccem-fg-dim); font-size: 13px;">
                No pending approvals
              </div>
            <% end %>
          </.card>

          <!-- Recent audit entries -->
          <.card padded={false}>
            <div style="padding: 16px 16px 0 16px; margin-bottom: 12px;">
              <span style="font-size: 13px; font-weight: 600; color: var(--ccem-fg);">Recent Decisions</span>
            </div>
            <.data_table id="audit-table" rows={@recent_audit}>
              <:col :let={entry} label="Decision">
                <.badge tone={audit_tone(Map.get(entry, :decision))}>
                  {Map.get(entry, :decision, "—")}
                </.badge>
              </:col>
              <:col :let={entry} label="Agent">{Map.get(entry, :agent_id, "—")}</:col>
              <:col :let={entry} label="Tool">{Map.get(entry, :tool_name, "—")}</:col>
              <:col :let={entry} label="By">{Map.get(entry, :decided_by, "—")}</:col>
              <:col :let={entry} label="Time">
                <span style="font-family: var(--ccem-font-mono); font-size: 11px; color: var(--ccem-fg-dim);">
                  {format_dt(Map.get(entry, :decided_at))}
                </span>
              </:col>
            </.data_table>
            <%= if @recent_audit == [] do %>
              <div style="padding: 40px; text-align: center; color: var(--ccem-fg-dim); font-size: 13px;">
                No recent decisions
              </div>
            <% end %>
          </.card>

        </div>
      </:main>
    </.page_layout>
    """
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_data(socket) do
    pending_items = catch_exit(fn -> apply(ApprovalQueue, :list_pending, []) end) || []
    recent_audit = catch_exit(fn -> apply(ApprovalAuditLog, :tail, [20]) end) || []

    today = Date.utc_today()

    approved_today =
      Enum.count(recent_audit, fn e ->
        Map.get(e, :decision) == :approved and
          match_today?(Map.get(e, :decided_at), today)
      end)

    denied_today =
      Enum.count(recent_audit, fn e ->
        Map.get(e, :decision) == :denied and
          match_today?(Map.get(e, :decided_at), today)
      end)

    socket
    |> assign(:pending_items, pending_items)
    |> assign(:pending_count, length(pending_items))
    |> assign(:recent_audit, recent_audit)
    |> assign(:approved_today, approved_today)
    |> assign(:denied_today, denied_today)
  end

  defp match_today?(%DateTime{} = dt, today), do: DateTime.to_date(dt) == today
  defp match_today?(_, _), do: false

  defp format_ttl(nil), do: "—"
  defp format_ttl(%DateTime{} = expires_at) do
    diff = DateTime.diff(expires_at, DateTime.utc_now(), :second)
    cond do
      diff <= 0 -> "expired"
      diff < 60 -> "#{diff}s"
      true -> "#{div(diff, 60)}m #{rem(diff, 60)}s"
    end
  end
  defp format_ttl(_), do: "—"

  defp catch_exit(fun) do
    try do
      fun.()
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)
    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end
  defp format_dt(_), do: "—"

  defp risk_tone(:high), do: "error"
  defp risk_tone(:medium), do: "warning"
  defp risk_tone(:low), do: "success"
  defp risk_tone(_), do: "neutral"

  defp audit_tone(:approved), do: "success"
  defp audit_tone(:denied), do: "error"
  defp audit_tone(:deferred), do: "warning"
  defp audit_tone(_), do: "neutral"
end
