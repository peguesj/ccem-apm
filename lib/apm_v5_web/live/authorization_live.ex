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
         policy_rules: safe_list_rules(),
         modal_minimized: true,
         auth_dismissed: false
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
    {:noreply, assign(socket, pending: PendingDecisions.list_pending(), auth_dismissed: false)}
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
  def handle_event("toggle_modal_minimize", _params, socket) do
    {:noreply, assign(socket, modal_minimized: !socket.assigns.modal_minimized, auth_dismissed: false)}
  end

  @impl true
  def handle_event("dismiss_auth", _params, socket) do
    {:noreply, assign(socket, :auth_dismissed, true)}
  end

  @impl true
  def handle_event("reshow_auth", _params, socket) do
    {:noreply, assign(socket, auth_dismissed: false, modal_minimized: true)}
  end

  @impl true
  def handle_event("approve_for", %{"id" => request_id, "minutes" => minutes_str}, socket) do
    minutes = String.to_integer(minutes_str)
    entry = Enum.find(socket.assigns.pending, &(&1.request_id == request_id))

    if entry do
      # Approve the immediate request
      PendingDecisions.decide(request_id, :approve)

      # Create a time-limited auto-approval policy
      ApmV5.Auth.AutoApprovalStore.create(%{
        agent_id: entry.agent_id,
        session_id: entry.session_id,
        allowed_tools: [entry.tool_name],
        allowed_risk_levels: :all,
        expires_at: DateTime.add(DateTime.utc_now(), minutes * 60, :second),
        created_by: "authorization_live",
        reason: "Approved #{entry.tool_name} for #{minutes}min via Authorization UI"
      })
    end

    {:noreply, assign(socket, pending: PendingDecisions.list_pending())}
  end

  @impl true
  def handle_event("always_allow_tool", %{"id" => request_id}, socket) do
    entry = Enum.find(socket.assigns.pending, &(&1.request_id == request_id))

    if entry do
      PendingDecisions.decide(request_id, :approve)

      # Create permanent auto-approval for this tool (24h TTL, effectively permanent)
      ApmV5.Auth.AutoApprovalStore.create(%{
        allowed_tools: [entry.tool_name],
        allowed_risk_levels: :all,
        expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second),
        created_by: "authorization_live",
        reason: "Always allow #{entry.tool_name} via Authorization UI"
      })
    end

    {:noreply, assign(socket, pending: PendingDecisions.list_pending())}
  end

  @impl true
  def handle_event("always_deny_tool", %{"id" => request_id}, socket) do
    entry = Enum.find(socket.assigns.pending, &(&1.request_id == request_id))

    if entry do
      PendingDecisions.decide(request_id, :deny)
      PolicyRulesStore.add_rule(entry.tool_name, :always_deny)
    end

    {:noreply,
     socket
     |> assign(pending: PendingDecisions.list_pending(), policy_rules: PolicyRulesStore.list_rules())}
  end

  @impl true
  def handle_event("approve_group", %{"agent" => agent_id}, socket) do
    socket.assigns.pending
    |> Enum.filter(&(&1.agent_id == agent_id))
    |> Enum.each(&PendingDecisions.decide(&1.request_id, :approve))

    {:noreply, assign(socket, pending: PendingDecisions.list_pending())}
  end

  @impl true
  def handle_event("deny_group", %{"agent" => agent_id}, socket) do
    socket.assigns.pending
    |> Enum.filter(&(&1.agent_id == agent_id))
    |> Enum.each(&PendingDecisions.decide(&1.request_id, :deny))

    {:noreply, assign(socket, pending: PendingDecisions.list_pending())}
  end

  @impl true
  def handle_event("approve_group_for", %{"agent" => agent_id, "minutes" => minutes_str}, socket) do
    minutes = String.to_integer(minutes_str)
    gates = Enum.filter(socket.assigns.pending, &(&1.agent_id == agent_id))

    Enum.each(gates, &PendingDecisions.decide(&1.request_id, :approve))

    # Create time-limited policy for the agent's tools
    tool_names = gates |> Enum.map(& &1.tool_name) |> Enum.uniq()
    ApmV5.Auth.AutoApprovalStore.create(%{
      agent_id: agent_id,
      allowed_tools: tool_names,
      allowed_risk_levels: :all,
      expires_at: DateTime.add(DateTime.utc_now(), minutes * 60, :second),
      created_by: "authorization_live",
      reason: "Approved #{length(tool_names)} tools for #{minutes}min via group action"
    })

    {:noreply, assign(socket, pending: PendingDecisions.list_pending())}
  end

  @impl true
  def handle_event("approve_all_pending", _params, socket) do
    Enum.each(socket.assigns.pending, fn p ->
      PendingDecisions.decide(p.request_id, :approve)
    end)

    {:noreply, assign(socket, pending: PendingDecisions.list_pending())}
  end

  @impl true
  def handle_event("dismiss_all_pending", _params, socket) do
    Enum.each(socket.assigns.pending, fn p ->
      PendingDecisions.decide(p.request_id, :deny)
    end)

    {:noreply, assign(socket, pending: PendingDecisions.list_pending())}
  end

  # ── Keyboard shortcut handlers ──────────────────────────────────────────────
  # Enter → approve first pending (only when panel visible)
  # Escape → minimize panel (dismiss, not deny)
  # Ctrl+D → deny first pending

  @impl true
  def handle_event("auth_keydown", %{"key" => "Enter"}, socket) do
    if socket.assigns.pending != [] and not socket.assigns.modal_minimized and not socket.assigns.auth_dismissed do
      [top | _] = socket.assigns.pending
      PendingDecisions.decide(top.request_id, :approve)
      {:noreply, assign(socket, pending: PendingDecisions.list_pending())}
    else
      # Minimized toast bar: Enter also approves first pending
      if socket.assigns.pending != [] and socket.assigns.modal_minimized and not socket.assigns.auth_dismissed do
        [top | _] = socket.assigns.pending
        PendingDecisions.decide(top.request_id, :approve)
        {:noreply, assign(socket, pending: PendingDecisions.list_pending())}
      else
        {:noreply, socket}
      end
    end
  end

  def handle_event("auth_keydown", %{"key" => "Escape"}, socket) do
    if socket.assigns.pending != [] and not socket.assigns.auth_dismissed do
      {:noreply, assign(socket, modal_minimized: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("auth_keydown", %{"key" => "d", "ctrlKey" => true}, socket) do
    if socket.assigns.pending != [] and not socket.assigns.auth_dismissed do
      [top | _] = socket.assigns.pending
      PendingDecisions.decide(top.request_id, :deny)
      {:noreply, assign(socket, pending: PendingDecisions.list_pending())}
    else
      {:noreply, socket}
    end
  end

  def handle_event("auth_keydown", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden" phx-window-keydown="auth_keydown">
      <.sidebar_nav current_path="/authorization" />

      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0 relative z-10">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">AgentLock Authorization</h2>
            <div class="badge badge-sm badge-ghost">{@summary.registered_tools} tools</div>
            <%= if length(@pending) > 0 do %>
              <button phx-click="reshow_auth" class="flex items-center gap-1.5 px-2 py-1 rounded bg-amber-500/10 border border-amber-500/30 hover:bg-amber-500/20 transition-colors">
                <.icon name="hero-bell-alert" class="h-4 w-4 text-amber-400 animate-pulse" />
                <span class="text-xs font-semibold text-amber-300"><%= length(@pending) %> pending</span>
              </button>
            <% end %>
          </div>
          <div class="flex items-center gap-2">
            <span class="text-xs text-base-content/40">Auto-refresh 5s</span>
          </div>
        </header>

        <%!-- Authorization Notification Panel — inline above main content --%>
        <%= if @pending != [] && !@modal_minimized && !@auth_dismissed do %>
          <div class="border-b border-amber-500/30 bg-gradient-to-b from-amber-950/30 to-base-300 relative z-20" role="alert" aria-live="assertive">
            <div class="px-4 py-3 space-y-2 max-h-[50vh] overflow-y-auto">
              <%!-- Panel header with count and dismiss controls --%>
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-2">
                  <.icon name="hero-shield-exclamation" class="h-5 w-5 text-amber-400" />
                  <h3 class="text-sm font-bold text-amber-300">Authorization Required</h3>
                  <span class="badge badge-sm badge-warning"><%= length(@pending) %></span>
                </div>
                <div class="flex items-center gap-1">
                  <button phx-click="dismiss_all_pending" class="btn btn-ghost btn-xs text-zinc-500 hover:text-red-400" title="Deny all">
                    Deny All
                  </button>
                  <button phx-click="toggle_modal_minimize" class="btn btn-ghost btn-xs btn-square" title="Minimize (Esc)">
                    <.icon name="hero-minus" class="h-3.5 w-3.5" />
                  </button>
                  <button phx-click="dismiss_auth" class="btn btn-ghost btn-xs btn-square" title="Dismiss (stays in Pending tab)">
                    <.icon name="hero-x-mark" class="h-3.5 w-3.5" />
                  </button>
                </div>
              </div>

              <%!-- Grouped authorization cards — combined by agent for simultaneous requests --%>
              <% grouped = group_pending_by_agent(@pending) %>
              <%= for {agent_id, gates} <- grouped do %>
                <% agent_lbl = NamespaceResolver.agent_label(agent_id) %>
                <% _tool_names = Enum.map(gates, & &1.tool_name) |> Enum.uniq() |> Enum.join(", ") %>
                <% max_risk = gates |> Enum.map(& &1.risk_level) |> Enum.max_by(&risk_weight/1) %>
                <div class="rounded-lg bg-base-200 border border-base-content/10 overflow-hidden">
                  <%!-- Group header --%>
                  <div class="px-3 py-2 bg-base-300/50 flex items-center justify-between">
                    <div class="flex items-center gap-2 min-w-0">
                      <.icon name="hero-user-circle" class="h-4 w-4 text-base-content/50 shrink-0" />
                      <span class="text-xs font-semibold truncate"><%= agent_lbl %></span>
                      <span class={"badge badge-xs #{risk_badge_class(max_risk)}"}><%= max_risk %></span>
                      <span class="text-xs text-base-content/40"><%= length(gates) %> request<%= if length(gates) > 1, do: "s" %></span>
                    </div>
                    <%!-- Batch actions for the group --%>
                    <div class="flex items-center gap-1">
                      <button phx-click="approve_group" phx-value-agent={agent_id} class="btn btn-success btn-xs gap-1" title="Approve all from this agent">
                        <.icon name="hero-check" class="h-3 w-3" /> All
                      </button>
                      <div class="dropdown dropdown-end dropdown-top">
                        <label tabindex="0" class="btn btn-info btn-xs btn-outline gap-1 cursor-pointer" title="Time-limited allow">
                          <.icon name="hero-clock" class="h-3 w-3" />
                        </label>
                        <ul tabindex="0" class="dropdown-content menu bg-base-100 rounded-box z-50 w-44 p-1 shadow-lg border border-base-content/10 mb-1">
                          <li class="menu-title text-[10px]">Allow all from this agent for:</li>
                          <li><button phx-click="approve_group_for" phx-value-agent={agent_id} phx-value-minutes="5" class="text-xs">5 minutes</button></li>
                          <li><button phx-click="approve_group_for" phx-value-agent={agent_id} phx-value-minutes="15" class="text-xs">15 minutes</button></li>
                          <li><button phx-click="approve_group_for" phx-value-agent={agent_id} phx-value-minutes="30" class="text-xs">30 minutes</button></li>
                          <li><button phx-click="approve_group_for" phx-value-agent={agent_id} phx-value-minutes="60" class="text-xs">1 hour</button></li>
                        </ul>
                      </div>
                      <button phx-click="deny_group" phx-value-agent={agent_id} class="btn btn-error btn-xs gap-1" title="Deny all from this agent">
                        <.icon name="hero-x-mark" class="h-3 w-3" /> All
                      </button>
                    </div>
                  </div>

                  <%!-- Individual requests within the group --%>
                  <div class="divide-y divide-base-content/5">
                    <%= for gate <- gates do %>
                      <% action_type_label = action_type_display(gate[:action_type]) %>
                      <% cmd_preview = extract_command_preview(gate.params) %>
                      <div class="px-3 py-2 space-y-1.5" id={"auth-card-#{gate.request_id}"}>
                        <div class="flex items-start justify-between gap-2">
                          <div class="min-w-0 flex-1">
                            <div class="flex items-center gap-1.5 flex-wrap">
                              <span class={"text-[10px] font-bold px-1 py-0.5 rounded #{action_type_class(gate[:action_type])}"}><%= action_type_label %></span>
                              <span class="text-xs font-semibold text-base-content"><%= gate.tool_name %></span>
                              <span class={"badge badge-xs #{risk_badge_class(gate.risk_level)}"}><%= gate.risk_level %></span>
                            </div>
                            <%!-- Description context --%>
                            <%= if gate[:action_detail] do %>
                              <p class="text-[11px] text-base-content/60 mt-0.5"><%= gate.action_detail %></p>
                            <% end %>
                            <%= if cmd_preview do %>
                              <pre class="font-mono text-[10px] bg-base-300 rounded px-1.5 py-0.5 mt-0.5 truncate text-zinc-400 max-w-lg"><%= cmd_preview %></pre>
                            <% end %>
                            <%= if gate[:approval_reasoning] do %>
                              <p class="text-[10px] text-amber-300/50 italic mt-0.5"><%= gate.approval_reasoning %></p>
                            <% end %>
                          </div>
                          <%!-- Per-item countdown + actions --%>
                          <div class="flex items-center gap-1.5 shrink-0">
                            <div
                              class="text-[10px] text-amber-400/60 font-mono tabular-nums"
                              phx-hook="CountdownTimer"
                              id={"countdown-#{gate.request_id}"}
                              data-seconds="20"
                            >
                              <span data-countdown-display>20s</span>
                            </div>
                            <button phx-click="approve_gate" phx-value-id={gate.request_id} class="btn btn-success btn-xs gap-1" title="Approve (Enter)">
                              <.icon name="hero-check" class="h-3 w-3" /> <kbd class="kbd kbd-xs ml-0.5 opacity-60">↵</kbd>
                            </button>
                            <button phx-click="deny_gate" phx-value-id={gate.request_id} class="btn btn-error btn-xs gap-1" title="Deny (Ctrl+D)">
                              <.icon name="hero-x-mark" class="h-3 w-3" /> <kbd class="kbd kbd-xs ml-0.5 opacity-60">ctrl+d</kbd>
                            </button>
                          </div>
                        </div>
                      </div>
                    <% end %>
                  </div>

                  <%!-- Group footer: tool-level always allow/deny --%>
                  <%= if length(Enum.uniq_by(gates, & &1.tool_name)) > 0 do %>
                    <div class="px-3 py-1.5 bg-base-300/30 flex items-center gap-1.5 flex-wrap text-[10px]">
                      <span class="text-base-content/40">Tools:</span>
                      <%= for tool <- Enum.uniq_by(gates, & &1.tool_name) do %>
                        <span class="badge badge-xs badge-ghost font-mono"><%= tool.tool_name %></span>
                        <button phx-click="always_allow_tool" phx-value-id={tool.request_id} class="text-success hover:underline">always allow</button>
                        <button phx-click="always_deny_tool" phx-value-id={tool.request_id} class="text-error hover:underline">always deny</button>
                        <span class="text-base-content/20">|</span>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%!-- Minimized toast bar — compact actionable strip when panel is collapsed --%>
        <%= if @pending != [] && @modal_minimized && !@auth_dismissed do %>
          <div class="border-b border-amber-500/20 bg-amber-950/20 px-4 py-2 relative z-20">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3 min-w-0 flex-1">
                <.icon name="hero-shield-exclamation" class="h-4 w-4 text-amber-400 shrink-0" />
                <% [top | _rest] = @pending %>
                <% agent_lbl = NamespaceResolver.agent_label(top.agent_id) %>
                <% cmd_preview = extract_command_preview(top.params) %>
                <span class="text-xs text-base-content/70 truncate">
                  <strong class="text-amber-300"><%= agent_lbl %></strong>
                  <span class="text-zinc-500 mx-1">&middot;</span>
                  <span class="font-mono"><%= top.tool_name %></span>
                  <%= if cmd_preview do %>
                    <span class="text-zinc-500 mx-1">&middot;</span>
                    <span class="text-zinc-400"><%= String.slice(to_string(cmd_preview), 0, 50) %></span>
                  <% end %>
                  <span class="text-zinc-500 mx-1">&middot;</span>
                  <span class={"font-semibold #{if top.risk_level in [:high, :critical], do: "text-red-400", else: "text-amber-400"}"}><%= top.risk_level %> risk</span>
                </span>
                <div phx-hook="CountdownTimer" id={"toast-cd-#{top.request_id}"} data-seconds="20"
                  class="text-[10px] font-mono text-amber-400/60 tabular-nums shrink-0">
                  <span data-countdown-display>20s</span>
                </div>
                <%= if length(@pending) > 1 do %>
                  <span class="badge badge-xs badge-warning shrink-0"><%= length(@pending) %></span>
                <% end %>
              </div>
              <div class="flex items-center gap-1.5 shrink-0 ml-2">
                <kbd class="kbd kbd-xs opacity-40">↵ approve</kbd>
                <kbd class="kbd kbd-xs opacity-40">esc dismiss</kbd>
                <button phx-click="approve_gate" phx-value-id={top.request_id} class="btn btn-success btn-xs">Approve</button>
                <button phx-click="deny_gate" phx-value-id={top.request_id} class="btn btn-error btn-xs">Deny</button>
                <%= if length(@pending) > 1 do %>
                  <div class="dropdown dropdown-end dropdown-bottom">
                    <label tabindex="0" class="btn btn-warning btn-xs btn-outline cursor-pointer" title="Approve all pending">
                      All (<%= length(@pending) %>)
                    </label>
                    <ul tabindex="0" class="dropdown-content menu bg-base-100 rounded-box z-50 w-40 p-1 shadow-lg border border-base-content/10 mt-1">
                      <li><button phx-click="approve_all_pending" class="text-xs text-success">Approve All</button></li>
                      <li><button phx-click="dismiss_all_pending" class="text-xs text-error">Deny All</button></li>
                    </ul>
                  </div>
                <% end %>
                <button phx-click="toggle_modal_minimize" class="btn btn-ghost btn-xs" title="Show details">
                  <.icon name="hero-chevron-down" class="h-3 w-3" />
                </button>
                <a href="/authorization" class="btn btn-ghost btn-xs" title="Open Authorization page">
                  <.icon name="hero-arrow-top-right-on-square" class="h-3 w-3" />
                </a>
                <button phx-click="dismiss_auth" class="btn btn-ghost btn-xs btn-square" title="Dismiss">
                  <.icon name="hero-x-mark" class="h-3 w-3" />
                </button>
              </div>
            </div>
          </div>
        <% end %>

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

  defp group_pending_by_agent(pending) do
    pending
    |> Enum.group_by(& &1.agent_id)
    |> Enum.sort_by(fn {_agent, gates} -> -length(gates) end)
  end

  defp risk_weight(:critical), do: 4
  defp risk_weight(:high), do: 3
  defp risk_weight(:medium), do: 2
  defp risk_weight(:low), do: 1
  defp risk_weight(_), do: 0

  defp action_type_display(nil), do: "OPERATION"
  defp action_type_display(:destructive), do: "DESTRUCTIVE"
  defp action_type_display(:write), do: "WRITE"
  defp action_type_display(:read), do: "READ"
  defp action_type_display(:unknown), do: "OPERATION"
  defp action_type_display(other), do: String.upcase(to_string(other))

  defp action_type_class(nil), do: "bg-zinc-700 text-zinc-300"
  defp action_type_class(:destructive), do: "bg-red-900/60 text-red-300"
  defp action_type_class(:write), do: "bg-amber-900/60 text-amber-300"
  defp action_type_class(:read), do: "bg-blue-900/60 text-blue-300"
  defp action_type_class(_), do: "bg-zinc-700 text-zinc-300"

  defp extract_command_preview(params) when is_map(params) do
    cond do
      Map.has_key?(params, "command") -> Map.get(params, "command")
      Map.has_key?(params, "file_path") -> "file: #{Map.get(params, "file_path")}"
      Map.has_key?(params, "pattern") -> "pattern: #{Map.get(params, "pattern")}"
      Map.has_key?(params, "description") -> Map.get(params, "description")
      true -> nil
    end
  end
  defp extract_command_preview(_), do: nil

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
