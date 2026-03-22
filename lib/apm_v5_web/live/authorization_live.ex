defmodule ApmV5Web.AuthorizationLive do
  @moduledoc """
  AgentLock Authorization dashboard LiveView.

  4-tab dashboard: Overview, Sessions, Audit Log, Policies.
  Subscribes to agentlock:* PubSub topics for live updates.
  """

  use ApmV5Web, :live_view

  alias ApmV5.Auth.{AuthorizationGate, SessionStore}

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "agentlock:authorization")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "agentlock:sessions")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "agentlock:trust")
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    {:ok, assign(socket, load_data() |> Map.merge(%{active_tab: "overview", page_title: "Authorization"}))}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, load_data())}
  end

  @impl true
  def handle_info({:auth_granted, _}, socket), do: {:noreply, assign(socket, load_data())}
  def handle_info({:auth_denied, _}, socket), do: {:noreply, assign(socket, load_data())}
  def handle_info({:auth_escalated, _}, socket), do: {:noreply, assign(socket, load_data())}
  def handle_info({:token_consumed, _}, socket), do: {:noreply, assign(socket, load_data())}
  def handle_info({:session_created, _}, socket), do: {:noreply, assign(socket, load_data())}
  def handle_info({:session_destroyed, _}, socket), do: {:noreply, assign(socket, load_data())}
  def handle_info({:session_expired, _}, socket), do: {:noreply, assign(socket, load_data())}
  def handle_info({:trust_ceiling_changed, _, _}, socket), do: {:noreply, assign(socket, load_data())}
  def handle_info({:context_recorded, _}, socket), do: {:noreply, assign(socket, load_data())}
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100">
      <div class="p-6">
        <h1 class="text-2xl font-bold mb-4">AgentLock Authorization</h1>

        <!-- Tabs -->
        <div class="tabs tabs-boxed mb-6">
          <button class={"tab #{if @active_tab == "overview", do: "tab-active"}"} phx-click="switch_tab" phx-value-tab="overview">Overview</button>
          <button class={"tab #{if @active_tab == "sessions", do: "tab-active"}"} phx-click="switch_tab" phx-value-tab="sessions">Sessions</button>
          <button class={"tab #{if @active_tab == "audit", do: "tab-active"}"} phx-click="switch_tab" phx-value-tab="audit">Audit Log</button>
          <button class={"tab #{if @active_tab == "policies", do: "tab-active"}"} phx-click="switch_tab" phx-value-tab="policies">Policies</button>
        </div>

        <!-- Overview Tab -->
        <%= if @active_tab == "overview" do %>
          <div class="grid grid-cols-4 gap-4 mb-6">
            <div class="stat bg-base-200 rounded-lg">
              <div class="stat-title">Registered Tools</div>
              <div class="stat-value text-primary"><%= @summary.registered_tools %></div>
            </div>
            <div class="stat bg-base-200 rounded-lg">
              <div class="stat-title">Active Sessions</div>
              <div class="stat-value text-info"><%= @summary.active_sessions %></div>
            </div>
            <div class="stat bg-base-200 rounded-lg">
              <div class="stat-title">Authorized</div>
              <div class="stat-value text-success"><%= @summary.total_authorized %></div>
            </div>
            <div class="stat bg-base-200 rounded-lg">
              <div class="stat-title">Denied</div>
              <div class="stat-value text-error"><%= @summary.total_denied %></div>
            </div>
          </div>

          <!-- Risk Distribution -->
          <div class="card bg-base-200 mb-4">
            <div class="card-body">
              <h3 class="card-title text-sm">Risk Distribution</h3>
              <div class="flex gap-2 flex-wrap">
                <%= for {level, count} <- @summary.risk_distribution || %{} do %>
                  <span class={"badge #{risk_badge_class(level)}"}><%= level %>: <%= count %></span>
                <% end %>
              </div>
            </div>
          </div>

          <!-- Token Stats -->
          <div class="card bg-base-200">
            <div class="card-body">
              <h3 class="card-title text-sm">Token Status</h3>
              <div class="flex gap-4">
                <span class="text-success">Active: <%= Map.get(@summary.tokens || %{}, :active, 0) %></span>
                <span class="text-base-content/60">Used: <%= Map.get(@summary.tokens || %{}, :used, 0) %></span>
                <span class="text-warning">Expired: <%= Map.get(@summary.tokens || %{}, :expired, 0) %></span>
              </div>
            </div>
          </div>
        <% end %>

        <!-- Sessions Tab -->
        <%= if @active_tab == "sessions" do %>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Session ID</th>
                  <th>User</th>
                  <th>Role</th>
                  <th>Trust</th>
                  <th>Tool Calls</th>
                  <th>Denied</th>
                  <th>Expires</th>
                </tr>
              </thead>
              <tbody>
                <%= for session <- @sessions do %>
                  <tr>
                    <td class="font-mono text-xs"><%= String.slice(session.id, 0..15) %></td>
                    <td><%= session.user_id %></td>
                    <td><span class="badge badge-sm"><%= session.role %></span></td>
                    <td><span class={"badge badge-sm #{trust_badge_class(session.trust_ceiling)}"}><%= session.trust_ceiling %></span></td>
                    <td><%= session.tool_call_count %></td>
                    <td class={if session.denied_count > 0, do: "text-error"}><%= session.denied_count %></td>
                    <td class="text-xs"><%= format_expiry(session.expires_at) %></td>
                  </tr>
                <% end %>
                <%= if @sessions == [] do %>
                  <tr><td colspan="7" class="text-center text-base-content/40">No active sessions</td></tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>

        <!-- Audit Tab -->
        <%= if @active_tab == "audit" do %>
          <div class="space-y-2">
            <%= for entry <- @audit_entries do %>
              <div class="card bg-base-200 card-compact">
                <div class="card-body flex-row items-center gap-4">
                  <span class={"badge badge-sm #{audit_action_class(entry)}"}><%= Map.get(entry, :event_type, "unknown") %></span>
                  <span class="font-mono text-xs"><%= Map.get(entry, :resource, "") %></span>
                  <span class="text-xs text-base-content/60 ml-auto"><%= Map.get(entry, :timestamp, "") %></span>
                </div>
              </div>
            <% end %>
            <%= if @audit_entries == [] do %>
              <p class="text-center text-base-content/40 py-8">No authorization audit entries yet</p>
            <% end %>
          </div>
        <% end %>

        <!-- Policies Tab -->
        <%= if @active_tab == "policies" do %>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Tool</th>
                  <th>Risk Level</th>
                  <th>Requires Auth</th>
                  <th>Allowed Roles</th>
                  <th>Data Boundary</th>
                </tr>
              </thead>
              <tbody>
                <%= for tool <- @tools do %>
                  <tr>
                    <td class="font-mono"><%= tool.name %></td>
                    <td><span class={"badge badge-sm #{risk_badge_class(tool.risk_level)}"}><%= tool.risk_level %></span></td>
                    <td><%= if tool.requires_auth, do: "Yes", else: "No" %></td>
                    <td class="text-xs"><%= if tool.allowed_roles == [], do: "Any", else: Enum.join(tool.allowed_roles, ", ") %></td>
                    <td class="text-xs"><%= tool.data_boundary %></td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_data do
    summary = try do AuthorizationGate.summary() rescue _ -> %{registered_tools: 0, active_sessions: 0, tokens: %{}, total_authorized: 0, total_denied: 0, total_escalated: 0, risk_distribution: %{}} end
    sessions = try do SessionStore.list_active() rescue _ -> [] end
    tools = try do AuthorizationGate.list_tools() rescue _ -> [] end
    audit_entries = try do
      ApmV5.AuditLog.tail(30)
      |> Enum.filter(fn e -> String.starts_with?(Map.get(e, :event_type, ""), "auth:") end)
    rescue _ -> [] end

    %{
      summary: summary,
      sessions: sessions,
      tools: tools,
      audit_entries: audit_entries
    }
  end

  defp risk_badge_class(level) do
    case level do
      :none -> "badge-success"
      :low -> "badge-info"
      :medium -> "badge-warning"
      :high -> "badge-error"
      :critical -> "badge-error badge-outline"
      _ -> "badge-ghost"
    end
  end

  defp trust_badge_class(level) do
    case level do
      :authoritative -> "badge-success"
      :derived -> "badge-warning"
      :untrusted -> "badge-error"
      _ -> "badge-ghost"
    end
  end

  defp audit_action_class(entry) do
    event = Map.get(entry, :event_type, "")
    cond do
      String.contains?(event, "granted") -> "badge-success"
      String.contains?(event, "denied") -> "badge-error"
      String.contains?(event, "escalated") -> "badge-warning"
      String.contains?(event, "consumed") -> "badge-info"
      true -> "badge-ghost"
    end
  end

  defp format_expiry(nil), do: "-"
  defp format_expiry(dt) do
    diff = DateTime.diff(dt, DateTime.utc_now(), :second)
    cond do
      diff <= 0 -> "Expired"
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m"
      true -> "#{div(diff, 3600)}h"
    end
  end
end
