defmodule ApmV5Web.AuthorizationLive do
  @moduledoc """
  AgentLock Authorization dashboard LiveView.

  4-tab dashboard: Overview, Sessions, Audit Log, Policies.
  Subscribes to agentlock:* PubSub topics for live updates.
  """

  use ApmV5Web, :live_view

  alias ApmV5.Auth.{AuthorizationGate, SessionStore, PendingDecisions, PolicyRulesStore}
  alias ApmV5.NamespaceResolver

  @refresh_ms 5_000

  @max_decisions 20

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "agentlock:authorization")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "agentlock:sessions")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "agentlock:trust")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:agentlock")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "agentlock:pending")
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    {:ok,
     assign(
       socket,
       load_data()
       |> Map.merge(%{
         active_tab: "overview",
         page_title: "Authorization",
         decisions: [],
         pending: safe_list_pending(),
         policy_rules: safe_list_rules()
       })
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, load_data())}
  end

  @impl true
  def handle_info({:auth_granted, %{tool_name: tool, risk_level: risk}}, socket) do
    socket = assign(socket, load_data())

    socket =
      if risk in [:high, :critical] do
        push_event(socket, "show_toast", %{
          type: "warning",
          title: "AgentLock: #{tool} authorized",
          message: "high risk operation permitted (#{risk})",
          category: "agentlock"
        })
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:auth_granted, _}, socket), do: {:noreply, assign(socket, load_data())}

  def handle_info({:auth_denied, %{tool_name: tool, risk_level: risk}}, socket) do
    socket =
      socket
      |> assign(load_data())
      |> push_event("show_toast", %{
        type: "error",
        title: "AgentLock: #{tool} DENIED",
        message: "risk: #{risk}",
        category: "agentlock"
      })

    {:noreply, socket}
  end

  def handle_info({:auth_denied, %{tool_name: tool}}, socket) do
    socket =
      socket
      |> assign(load_data())
      |> push_event("show_toast", %{
        type: "error",
        title: "AgentLock: #{tool} DENIED",
        message: "access denied by policy",
        category: "agentlock"
      })

    {:noreply, socket}
  end

  def handle_info({:auth_escalated, %{tool_name: tool}}, socket) do
    socket =
      socket
      |> assign(load_data())
      |> push_event("show_toast", %{
        type: "warning",
        title: "AgentLock: #{tool} escalated",
        message: "approval required",
        category: "agentlock"
      })

    {:noreply, socket}
  end

  def handle_info({:auth_rate_limited, %{tool_name: tool, retry_after_ms: retry_ms}}, socket) do
    socket =
      socket
      |> assign(load_data())
      |> push_event("show_toast", %{
        type: "warning",
        title: "AgentLock: rate limit hit",
        message: "#{tool} — retry after #{div(retry_ms, 1000)}s",
        category: "agentlock"
      })

    {:noreply, socket}
  end

  def handle_info({:auth_rate_limited, _}, socket), do: {:noreply, assign(socket, load_data())}
  def handle_info({:token_consumed, _}, socket), do: {:noreply, assign(socket, load_data())}
  def handle_info({:session_created, _}, socket), do: {:noreply, assign(socket, load_data())}
  def handle_info({:session_destroyed, _}, socket), do: {:noreply, assign(socket, load_data())}
  def handle_info({:session_expired, _}, socket), do: {:noreply, assign(socket, load_data())}
  def handle_info({:trust_ceiling_changed, _, _}, socket), do: {:noreply, assign(socket, load_data())}
  def handle_info({:context_recorded, _}, socket), do: {:noreply, assign(socket, load_data())}

  def handle_info(%{event: "authorization_decision"} = msg, socket) do
    entry = %{
      tool: Map.get(msg, :tool, "unknown"),
      status: Map.get(msg, :status, :unknown),
      risk_level: Map.get(msg, :risk_level, :none),
      session_id: Map.get(msg, :session_id, ""),
      timestamp: Map.get(msg, :timestamp, DateTime.utc_now() |> DateTime.to_iso8601())
    }

    updated = [entry | socket.assigns.decisions] |> Enum.take(@max_decisions)
    {:noreply, assign(socket, :decisions, updated)}
  end

  def handle_info({:pending_decision_added, _entry}, socket) do
    {:noreply, assign(socket, pending: PendingDecisions.list_pending())}
  end

  def handle_info({:pending_decision_resolved, _entry}, socket) do
    {:noreply, assign(socket, pending: PendingDecisions.list_pending())}
  end

  def handle_info({:policy_rule_added, _rule}, socket) do
    {:noreply, assign(socket, policy_rules: PolicyRulesStore.list_rules())}
  end

  def handle_info({:policy_rule_removed, _rule}, socket) do
    {:noreply, assign(socket, policy_rules: PolicyRulesStore.list_rules())}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("approve", %{"id" => request_id}, socket) do
    PendingDecisions.decide(request_id, :approve)
    {:noreply, assign(socket, pending: PendingDecisions.list_pending())}
  end

  @impl true
  def handle_event("deny", %{"id" => request_id}, socket) do
    PendingDecisions.decide(request_id, :deny)
    {:noreply, assign(socket, pending: PendingDecisions.list_pending())}
  end

  @impl true
  def handle_event("approve_gate", %{"id" => request_id}, socket) do
    PendingDecisions.decide(request_id, :approve)
    {:noreply, assign(socket, pending: PendingDecisions.list_pending())}
  end

  @impl true
  def handle_event("deny_gate", %{"id" => request_id}, socket) do
    PendingDecisions.decide(request_id, :deny)
    {:noreply, assign(socket, pending: PendingDecisions.list_pending())}
  end

  @impl true
  def handle_event("always_allow", %{"tool" => tool_name}, socket) do
    PolicyRulesStore.add_rule(tool_name, :always_allow)

    {:noreply,
     socket
     |> assign(policy_rules: PolicyRulesStore.list_rules())
     |> push_event("show_toast", %{
       type: "success",
       title: "Policy rule added",
       message: "#{tool_name} → always allow",
       category: "agentlock"
     })}
  end

  @impl true
  def handle_event("always_deny", %{"tool" => tool_name}, socket) do
    PolicyRulesStore.add_rule(tool_name, :always_deny)

    {:noreply,
     socket
     |> assign(policy_rules: PolicyRulesStore.list_rules())
     |> push_event("show_toast", %{
       type: "warning",
       title: "Policy rule added",
       message: "#{tool_name} → always deny",
       category: "agentlock"
     })}
  end

  @impl true
  def handle_event("remove_rule", %{"tool" => tool_name}, socket) do
    PolicyRulesStore.remove_rule(tool_name)
    {:noreply, assign(socket, policy_rules: PolicyRulesStore.list_rules())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <%!-- US-003: Full-screen AgentLock approval modal — shown when pending decisions exist --%>
      <%= if @pending != [] do %>
        <% [top_gate | _rest] = @pending %>
        <% label = NamespaceResolver.gate_label(top_gate.request_id, top_gate.tool_name) %>
        <% agent_lbl = NamespaceResolver.agent_label(top_gate.agent_id) %>
        <div
          id="agentlock-approval-modal"
          class="fixed inset-0 z-[9999] flex items-center justify-center bg-black/70 backdrop-blur-sm"
          role="dialog"
          aria-modal="true"
          aria-labelledby="modal-title"
        >
          <div class="bg-base-200 border border-amber-500/60 rounded-xl shadow-2xl w-full max-w-md mx-4 p-6">
            <div class="flex items-center gap-3 mb-4">
              <.icon name="hero-shield-exclamation" class="h-7 w-7 text-amber-400 shrink-0" />
              <div>
                <h2 id="modal-title" class="text-base font-bold text-amber-300">AgentLock — Approval Required</h2>
                <%= if length(@pending) > 1 do %>
                  <p class="text-xs text-zinc-400 mt-0.5"><%= length(@pending) %> pending · showing most recent</p>
                <% end %>
              </div>
            </div>

            <div class="space-y-3 mb-5">
              <div class="rounded-lg bg-base-300 border border-base-content/10 px-4 py-3 space-y-1.5">
                <div class="flex items-center justify-between text-xs">
                  <span class="text-base-content/50">Tool</span>
                  <span class="font-mono font-semibold text-amber-300"><%= label %></span>
                </div>
                <div class="flex items-center justify-between text-xs">
                  <span class="text-base-content/50">Agent</span>
                  <span class="font-mono text-zinc-300"><%= agent_lbl %></span>
                </div>
                <div class="flex items-center justify-between text-xs">
                  <span class="text-base-content/50">Risk</span>
                  <span class={"badge badge-sm #{risk_badge_class(top_gate.risk_level)}"}><%= top_gate.risk_level %></span>
                </div>
                <div class="flex items-center justify-between text-xs">
                  <span class="text-base-content/50">Session</span>
                  <span class="font-mono text-zinc-400"><%= truncate_session(top_gate.session_id) %></span>
                </div>
                <%= if map_size(top_gate.params) > 0 do %>
                  <div class="mt-2 pt-2 border-t border-base-content/10">
                    <span class="text-xs text-base-content/50 block mb-1">Params</span>
                    <div class="text-xs font-mono bg-base-100 rounded p-2 truncate text-zinc-300">
                      <%= inspect(top_gate.params) %>
                    </div>
                  </div>
                <% end %>
              </div>

              <%!-- Countdown --%>
              <div
                class="flex items-center gap-2 text-xs text-amber-400/70"
                phx-hook="CountdownTimer"
                id={"modal-countdown-#{top_gate.request_id}"}
                data-seconds="20"
                data-gate-id={top_gate.request_id}
              >
                <.icon name="hero-clock" class="h-3.5 w-3.5" />
                <span>Auto-expires in </span>
                <span class="font-mono tabular-nums font-semibold" data-countdown-display>20s</span>
                <span>— decision required</span>
              </div>
            </div>

            <div class="flex gap-3">
              <button
                phx-click="approve_gate"
                phx-value-id={top_gate.request_id}
                class="btn btn-success flex-1 gap-2"
              >
                <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
                </svg>
                Approve
              </button>
              <button
                phx-click="deny_gate"
                phx-value-id={top_gate.request_id}
                class="btn btn-error flex-1 gap-2"
              >
                <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                </svg>
                Deny
              </button>
            </div>

            <%= if length(@pending) > 1 do %>
              <p class="text-center text-xs text-base-content/40 mt-3">
                Additional requests visible in the Pending tab below
              </p>
            <% end %>
          </div>
        </div>
      <% end %>

      <.sidebar_nav current_path="/authorization" />

      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0 relative z-10">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">AgentLock Authorization</h2>
            <div class="badge badge-sm badge-ghost">{@summary.registered_tools} tools</div>
          </div>
          <div class="flex items-center gap-2">
            <span class="text-xs text-base-content/40">Auto-refresh 5s</span>
          </div>
        </header>

        <main class="flex-1 overflow-y-auto p-4 space-y-4">

        <!-- Tabs -->
        <div class="tabs tabs-boxed mb-4">
          <button class={"tab #{if @active_tab == "overview", do: "tab-active"}"} phx-click="switch_tab" phx-value-tab="overview">Overview</button>
          <button class={"tab #{if @active_tab == "sessions", do: "tab-active"}"} phx-click="switch_tab" phx-value-tab="sessions">Sessions</button>
          <button class={"tab #{if @active_tab == "audit", do: "tab-active"}"} phx-click="switch_tab" phx-value-tab="audit">Audit Log</button>
          <button class={"tab #{if @active_tab == "policies", do: "tab-active"}"} phx-click="switch_tab" phx-value-tab="policies">
            Policies
            <%= if length(@policy_rules) > 0 do %>
              <span class="badge badge-xs badge-accent ml-1"><%= length(@policy_rules) %></span>
            <% end %>
          </button>
          <button class={"tab #{if @active_tab == "pending", do: "tab-active"} #{if length(@pending) > 0, do: "text-warning font-semibold"}"} phx-click="switch_tab" phx-value-tab="pending">
            Pending
            <%= if length(@pending) > 0 do %>
              <span class="badge badge-xs badge-warning ml-1 animate-pulse"><%= length(@pending) %></span>
            <% end %>
          </button>
          <button class={"tab #{if @active_tab == "feed", do: "tab-active"}"} phx-click="switch_tab" phx-value-tab="feed">
            Live Feed
            <%= if length(@decisions) > 0 do %>
              <span class="badge badge-xs badge-primary ml-1"><%= length(@decisions) %></span>
            <% end %>
          </button>
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

        <!-- Pending Decisions Tab — human-in-the-loop approvals -->
        <%= if @active_tab == "pending" do %>
          <div class="space-y-3" id="agentlock-pending">
            <%= if @pending == [] do %>
              <div class="flex flex-col items-center justify-center py-12 text-base-content/40">
                <svg xmlns="http://www.w3.org/2000/svg" class="h-8 w-8 mb-2 opacity-30" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6-6a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                <p class="text-sm">No pending approval requests</p>
                <p class="text-xs mt-1 opacity-60">High-risk tool calls awaiting your approval will appear here</p>
              </div>
            <% else %>
              <%= for req <- @pending do %>
                <div class="card bg-base-200 border border-warning/40">
                  <div class="card-body p-4">
                    <div class="flex items-start justify-between gap-4">
                      <div class="flex-1 min-w-0">
                        <div class="flex items-center gap-2 mb-1">
                          <span class="font-mono font-semibold text-sm"><%= req.tool_name %></span>
                          <span class={"badge badge-sm #{risk_badge_class(req.risk_level)}"}><%= req.risk_level %></span>
                          <span class="badge badge-xs badge-warning">pending</span>
                        </div>
                        <div class="text-xs text-base-content/50 font-mono mb-2">
                          <span>agent: <%= String.slice(to_string(req.agent_id), 0..20) %></span>
                          <span class="mx-2">·</span>
                          <span>session: <%= truncate_session(req.session_id) %></span>
                          <span class="mx-2">·</span>
                          <span>expires <%= relative_time(DateTime.to_iso8601(req.expires_at)) %></span>
                        </div>
                        <%= if map_size(req.params) > 0 do %>
                          <div class="text-xs font-mono bg-base-300 rounded p-2 mt-1 truncate">
                            <%= inspect(req.params) %>
                          </div>
                        <% end %>
                      </div>
                      <!-- Action buttons -->
                      <div class="flex flex-col gap-1.5 flex-shrink-0">
                        <button
                          phx-click="approve"
                          phx-value-id={req.request_id}
                          class="btn btn-sm btn-success gap-1"
                        >
                          <svg xmlns="http://www.w3.org/2000/svg" class="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
                          </svg>
                          Approve
                        </button>
                        <button
                          phx-click="deny"
                          phx-value-id={req.request_id}
                          class="btn btn-sm btn-error gap-1"
                        >
                          <svg xmlns="http://www.w3.org/2000/svg" class="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                          </svg>
                          Deny
                        </button>
                        <button
                          phx-click="always_allow"
                          phx-value-tool={req.tool_name}
                          class="btn btn-sm btn-ghost btn-xs text-success gap-1"
                          title="Add permanent allow rule for this tool"
                        >
                          ∞ Always Allow
                        </button>
                        <button
                          phx-click="always_deny"
                          phx-value-tool={req.tool_name}
                          class="btn btn-sm btn-ghost btn-xs text-error gap-1"
                          title="Add permanent deny rule for this tool"
                        >
                          ∞ Always Deny
                        </button>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>
        <% end %>

        <!-- Live Feed Tab -->
        <%= if @active_tab == "feed" do %>
          <div class="space-y-1" id="agentlock-live-feed">
            <%= if @decisions == [] do %>
              <div class="flex flex-col items-center justify-center py-12 text-base-content/40">
                <svg xmlns="http://www.w3.org/2000/svg" class="h-8 w-8 mb-2 opacity-30" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z" />
                </svg>
                <p class="text-sm">Waiting for authorization decisions&hellip;</p>
                <p class="text-xs mt-1 opacity-60">Decisions appear here in real time</p>
              </div>
            <% else %>
              <%= for {decision, idx} <- Enum.with_index(@decisions) do %>
                <div class={"flex items-center gap-3 px-3 py-2 rounded-lg bg-base-200 #{if idx == 0, do: "ring-1 ring-primary/30 animate-pulse-once"}"}>
                  <!-- Status badge -->
                  <span class={"badge badge-sm font-mono #{decision_status_class(decision.status)}"}>
                    <%= decision_status_label(decision.status) %>
                  </span>
                  <!-- Tool name -->
                  <span class="font-mono text-xs font-medium flex-1 truncate"><%= decision.tool %></span>
                  <!-- Risk badge -->
                  <span class={"badge badge-xs #{risk_badge_class(decision.risk_level)}"}>
                    <%= decision.risk_level %>
                  </span>
                  <!-- Quick action buttons for escalated decisions -->
                  <%= if decision.status in [:escalated, "escalated"] do %>
                    <button phx-click="always_allow" phx-value-tool={decision.tool}
                      class="btn btn-xs btn-success gap-0.5" title="Always allow this tool">
                      ∞ Allow
                    </button>
                    <button phx-click="always_deny" phx-value-tool={decision.tool}
                      class="btn btn-xs btn-error gap-0.5" title="Always deny this tool">
                      ∞ Deny
                    </button>
                  <% end %>
                  <!-- Session ID truncated -->
                  <span class="font-mono text-xs text-base-content/40 hidden sm:inline">
                    <%= truncate_session(decision.session_id) %>
                  </span>
                  <!-- Relative timestamp -->
                  <span class="text-xs text-base-content/40 whitespace-nowrap">
                    <%= relative_time(decision.timestamp) %>
                  </span>
                </div>
              <% end %>
            <% end %>
          </div>
        <% end %>

        <!-- Policies Tab — tool risk table + permanent rules -->
        <%= if @active_tab == "policies" do %>
          <!-- Permanent Rules Section -->
          <div class="mb-6">
            <div class="flex items-center justify-between mb-3">
              <h3 class="text-sm font-semibold text-base-content">Permanent Rules</h3>
              <span class="text-xs text-base-content/40">Override normal policy evaluation for specific tools</span>
            </div>
            <%= if @policy_rules == [] do %>
              <div class="rounded-lg bg-base-200 px-4 py-3 text-sm text-base-content/50">
                No permanent rules. Use Approve/Deny with "Always" options to add rules.
              </div>
            <% else %>
              <div class="space-y-1.5">
                <%= for rule <- @policy_rules do %>
                  <div class="flex items-center gap-3 px-3 py-2 rounded-lg bg-base-200">
                    <span class="font-mono text-sm flex-1"><%= rule.tool_name %></span>
                    <span class={"badge badge-sm #{if rule.action == :always_allow, do: "badge-success", else: "badge-error"}"}>
                      <%= if rule.action == :always_allow, do: "always allow", else: "always deny" %>
                    </span>
                    <span class="text-xs text-base-content/40"><%= relative_time(rule.inserted_at) %></span>
                    <button
                      phx-click="remove_rule"
                      phx-value-tool={rule.tool_name}
                      class="btn btn-ghost btn-xs text-base-content/40 hover:text-error"
                      title="Remove rule"
                    >
                      ✕
                    </button>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
          <div class="divider"></div>
          <!-- Default tool policies table -->
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Tool</th>
                  <th>Risk Level</th>
                  <th>Requires Auth</th>
                  <th>Allowed Roles</th>
                  <th>Data Boundary</th>
                  <th>Actions</th>
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
                    <td class="flex gap-1">
                      <button phx-click="always_allow" phx-value-tool={tool.name}
                        class="btn btn-xs btn-ghost text-success" title="Always allow">∞ Allow</button>
                      <button phx-click="always_deny" phx-value-tool={tool.name}
                        class="btn btn-xs btn-ghost text-error" title="Always deny">∞ Deny</button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>

        </main>
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

  defp safe_list_pending do
    try do PendingDecisions.list_pending() rescue _ -> [] end
  end

  defp safe_list_rules do
    try do PolicyRulesStore.list_rules() rescue _ -> [] end
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

  defp decision_status_class(status) do
    case status do
      :granted -> "badge-success"
      :denied -> "badge-error"
      :rate_limited -> "badge-warning"
      _ -> "badge-ghost"
    end
  end

  defp decision_status_label(status) do
    case status do
      :granted -> "GRANTED"
      :denied -> "DENIED"
      :rate_limited -> "RATE LIMITED"
      _ -> to_string(status) |> String.upcase()
    end
  end

  defp truncate_session(""), do: "—"
  defp truncate_session(nil), do: "—"
  defp truncate_session(id) when byte_size(id) > 12 do
    String.slice(id, 0..11) <> "…"
  end
  defp truncate_session(id), do: id

  defp relative_time(nil), do: ""
  defp relative_time(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)
        cond do
          diff < 5 -> "just now"
          diff < 60 -> "#{diff}s ago"
          diff < 3600 -> "#{div(diff, 60)}m ago"
          true -> "#{div(diff, 3600)}h ago"
        end
      _ ->
        ""
    end
  end
end
