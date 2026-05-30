defmodule ApmV5Web.AuthorizationLive do
  @moduledoc """
  Govern — Authorization v9 LiveView (CP-178 / US-453).

  Redesigned with the CCEM Design System component shell:
  - `page_layout` three-zone shell (sidebar · main · inspector)
  - `top_bar` 48px top header
  - Stat tiles: Active Gates / Decisions Today / Avg TTL
  - `gauge` for the 20-second TTL countdown (server-side tick via `:timer.send_interval/2`)
  - `data_table` for policy rules
  - `ds_input` + `btn` scope-test panel
  - Audit log with `badge` decision indicators
  - `inspector_panel` with selection detail and filter slots

  All original AgentLock PubSub subscriptions, event handlers, and approval
  workflows are preserved from the previous implementation.
  """

  use ApmV5Web, :live_view

  alias ApmV5.Auth.{AuthorizationGate, PendingDecisions, PolicyRulesStore, SessionStore}
  alias ApmV5.NamespaceResolver

  @refresh_ms 5_000
  @max_decisions 20
  @pubsub_sessions_topic "apm:sessions"
  @ttl_max 20

  # ---------------------------------------------------------------------------
  # Mount
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "agentlock:authorization")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "agentlock:sessions")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "agentlock:trust")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:agentlock")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "agentlock:pending")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_sessions_topic)
      Process.send_after(self(), :refresh, @refresh_ms)
      :timer.send_interval(1_000, :tick_ttl)
    end

    pending = safe_list_pending()
    data = load_data()

    {:ok,
     socket
     |> assign(
       data
       |> Map.merge(%{
         page_title: "Authorization v9",
         active_tab: "overview",
         decisions: load_recent_decisions(),
         pending: pending,
         policy_rules: safe_list_rules(),
         modal_minimized: true,
         auth_dismissed: false,
         selected_ids: MapSet.new(),
         show_settings_modal: false,
         approval_display_mode: load_persisted_display_mode(),
         show_behavior_menu: false,
         risk_eval_mode: :automatic,
         risk_threshold: 50,
         timeout_seconds: 20,
         redaction_mode: :auto,
         sidebar_collapsed: false,
         inspector_open: false,
         inspector_mode: "filters",
         ttl_max: @ttl_max,
         ttl_remaining: if(pending != [], do: @ttl_max, else: 0),
         scope_test_input: %{"tool_name" => "", "scope" => ""},
         scope_test_result: nil,
         auth_stats: build_auth_stats(data),
         selected_decision: nil
       })
     )
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  # ---------------------------------------------------------------------------
  # handle_info
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    data = load_data()
    {:noreply, socket |> assign(data) |> assign(:auth_stats, build_auth_stats(data))}
  end

  @impl true
  def handle_info(:tick_ttl, socket) do
    ttl =
      if socket.assigns.pending != [] do
        max(socket.assigns.ttl_remaining - 1, 0)
      else
        0
      end

    {:noreply, assign(socket, :ttl_remaining, ttl)}
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
    {:noreply,
     socket
     |> assign(load_data())
     |> push_event("show_toast", %{
       type: "error",
       title: "AgentLock: #{tool} DENIED",
       message: "risk: #{risk}",
       category: "agentlock"
     })}
  end

  def handle_info({:auth_denied, %{tool_name: tool}}, socket) do
    {:noreply,
     socket
     |> assign(load_data())
     |> push_event("show_toast", %{
       type: "error",
       title: "AgentLock: #{tool} DENIED",
       message: "access denied by policy",
       category: "agentlock"
     })}
  end

  def handle_info({:auth_escalated, %{tool_name: tool} = payload}, socket) do
    socket = assign(socket, load_data())
    mode = socket.assigns.approval_display_mode
    pending = socket.assigns.pending
    request_id = Map.get(payload, :request_id) || top_pending_request_id(pending)

    socket =
      case mode do
        :always_modal ->
          # Surface the blocking modal (un-dismiss + un-minimize).
          assign(socket, auth_dismissed: false, modal_minimized: false)

        :toast_actions ->
          push_event(socket, "show_toast", %{
            type: "warning",
            title: "AgentLock: #{tool}",
            message: "Approval required — Enter approve · Esc/D deny",
            category: "agentlock",
            duration: 20_000,
            request_id: request_id,
            actions: ["approve", "deny"]
          })

        _toast_click ->
          push_event(socket, "show_toast", %{
            type: "warning",
            title: "AgentLock: #{tool}",
            message: "Approval required — click to review",
            category: "agentlock",
            duration: 20_000,
            request_id: request_id,
            open_modal: true
          })
      end

    {:noreply, socket}
  end

  def handle_info({:auth_escalated, _}, socket) do
    {:noreply, assign(socket, load_data())}
  end

  def handle_info({:auth_rate_limited, %{tool_name: tool, retry_after_ms: retry_ms}}, socket) do
    {:noreply,
     socket
     |> assign(load_data())
     |> push_event("show_toast", %{
       type: "warning",
       title: "AgentLock: rate limit hit",
       message: "#{tool} — retry after #{div(retry_ms, 1000)}s",
       category: "agentlock"
     })}
  end

  def handle_info({:auth_rate_limited, _}, socket), do: {:noreply, assign(socket, load_data())}
  def handle_info({:token_consumed, _}, socket), do: {:noreply, assign(socket, load_data())}
  def handle_info({:session_created, _}, socket), do: {:noreply, assign(socket, load_data())}
  def handle_info({:session_destroyed, _}, socket), do: {:noreply, assign(socket, load_data())}
  def handle_info({:session_expired, _}, socket), do: {:noreply, assign(socket, load_data())}

  def handle_info({:trust_ceiling_changed, _, _}, socket),
    do: {:noreply, assign(socket, load_data())}

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
    pending = PendingDecisions.list_pending()

    {:noreply,
     socket
     |> assign(pending: pending, auth_dismissed: false)
     |> assign(:ttl_remaining, if(pending != [], do: @ttl_max, else: 0))}
  end

  def handle_info({:approval_batch, _entries}, socket) do
    pending = PendingDecisions.list_pending()

    {:noreply,
     socket
     |> assign(pending: pending, auth_dismissed: false)
     |> assign(:ttl_remaining, if(pending != [], do: @ttl_max, else: 0))}
  end

  def handle_info({:pending_decision_resolved, _entry}, socket) do
    pending = PendingDecisions.list_pending()

    {:noreply,
     socket
     |> assign(:pending, pending)
     |> assign(:ttl_remaining, if(pending != [], do: @ttl_max, else: 0))}
  end

  def handle_info({:policy_rule_added, _rule}, socket) do
    {:noreply, assign(socket, policy_rules: PolicyRulesStore.list_rules())}
  end

  def handle_info({:policy_rule_removed, _rule}, socket) do
    {:noreply, assign(socket, policy_rules: PolicyRulesStore.list_rules())}
  end

  def handle_info({:sessions_updated, sessions}, socket) do
    {:noreply, assign(socket, :sessions, sessions)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # handle_event — DS layout controls
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_collapsed, !socket.assigns.sidebar_collapsed)}
  end

  @impl true
  def handle_event("toggle_inspector", _params, socket) do
    {:noreply, assign(socket, :inspector_open, !socket.assigns.inspector_open)}
  end

  @impl true
  def handle_event("inspector_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, inspector_mode: mode, inspector_open: true)}
  end

  @impl true
  def handle_event("update_scope_test", %{"field" => field, "value" => value}, socket) do
    updated = Map.put(socket.assigns.scope_test_input, field, value)
    {:noreply, assign(socket, :scope_test_input, updated)}
  end

  @impl true
  def handle_event("test_authorization", _params, socket) do
    tool_name = get_in(socket.assigns.scope_test_input, ["tool_name"]) || ""
    scope = get_in(socket.assigns.scope_test_input, ["scope"]) || ""

    result =
      if tool_name == "" do
        %{status: "error", message: "Tool name is required"}
      else
        try do
          tools = AuthorizationGate.list_tools()

          case Enum.find(tools, &(to_string(&1.name) == tool_name)) do
            nil ->
              %{status: "warning", message: "Tool '#{tool_name}' not registered"}

            tool ->
              if tool.requires_auth do
                rules = PolicyRulesStore.list_rules()
                rule = Enum.find(rules, &(to_string(&1.tool_name) == tool_name))

                case rule do
                  %{action: :always_allow} ->
                    %{status: "success", message: "GRANT — permanent allow rule active"}

                  %{action: :always_deny} ->
                    %{status: "error", message: "DENY — permanent deny rule active"}

                  _ ->
                    scoped = if scope != "", do: " (scope: #{scope})", else: ""

                    %{
                      status: "warning",
                      message:
                        "ESCALATE — requires approval#{scoped} (risk: #{tool.risk_level})"
                    }
                end
              else
                %{status: "success", message: "GRANT — no authorization required for #{tool_name}"}
              end
          end
        rescue
          _ -> %{status: "error", message: "Authorization check failed"}
        catch
          :exit, _ -> %{status: "error", message: "Auth gate unavailable"}
        end
      end

    {:noreply,
     socket
     |> assign(:scope_test_result, result)
     |> assign(:inspector_open, true)
     |> assign(:inspector_mode, "selection")}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("switch_tab_display", %{"value" => display}, socket) do
    tab =
      case display do
        "Overview" -> "overview"
        "Policy Rules" -> "policies"
        "Pending" -> "pending"
        "Audit Log" -> "audit"
        _ -> "overview"
      end

    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("select_decision", %{"idx" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    decision = Enum.at(socket.assigns.decisions, idx)

    {:noreply,
     socket
     |> assign(:selected_decision, decision)
     |> assign(:inspector_open, true)
     |> assign(:inspector_mode, "selection")}
  end

  # ---------------------------------------------------------------------------
  # handle_event — AgentLock approval workflows (preserved)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("approve", %{"id" => request_id}, socket) do
    PendingDecisions.decide(request_id, :approve)
    pending = PendingDecisions.list_pending()

    {:noreply,
     socket
     |> assign(:pending, pending)
     |> assign(:ttl_remaining, if(pending != [], do: @ttl_max, else: 0))}
  end

  @impl true
  def handle_event("deny", %{"id" => request_id}, socket) do
    PendingDecisions.decide(request_id, :deny)
    pending = PendingDecisions.list_pending()

    {:noreply,
     socket
     |> assign(:pending, pending)
     |> assign(:ttl_remaining, if(pending != [], do: @ttl_max, else: 0))}
  end

  @impl true
  def handle_event("approve_gate", %{"id" => request_id}, socket) do
    PendingDecisions.decide(request_id, :approve)
    pending = PendingDecisions.list_pending()

    {:noreply,
     socket
     |> assign(:pending, pending)
     |> assign(:ttl_remaining, if(pending != [], do: @ttl_max, else: 0))}
  end

  @impl true
  def handle_event("deny_gate", %{"id" => request_id}, socket) do
    PendingDecisions.decide(request_id, :deny)
    pending = PendingDecisions.list_pending()

    {:noreply,
     socket
     |> assign(:pending, pending)
     |> assign(:ttl_remaining, if(pending != [], do: @ttl_max, else: 0))}
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
    {:noreply,
     assign(socket, modal_minimized: !socket.assigns.modal_minimized, auth_dismissed: false)}
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
      PendingDecisions.decide(request_id, :approve)

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
     |> assign(
       pending: PendingDecisions.list_pending(),
       policy_rules: PolicyRulesStore.list_rules()
     )}
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
    Enum.each(socket.assigns.pending, &PendingDecisions.decide(&1.request_id, :approve))
    {:noreply, assign(socket, pending: PendingDecisions.list_pending())}
  end

  @impl true
  def handle_event("dismiss_all_pending", _params, socket) do
    Enum.each(socket.assigns.pending, &PendingDecisions.decide(&1.request_id, :deny))
    {:noreply, assign(socket, pending: PendingDecisions.list_pending())}
  end

  @impl true
  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected = socket.assigns.selected_ids

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, selected_ids: selected)}
  end

  @impl true
  def handle_event("select_all", _params, socket) do
    all_ids = socket.assigns.pending |> Enum.map(& &1.request_id) |> MapSet.new()
    {:noreply, assign(socket, selected_ids: all_ids)}
  end

  @impl true
  def handle_event("select_none", _params, socket) do
    {:noreply, assign(socket, selected_ids: MapSet.new())}
  end

  @impl true
  def handle_event("approve_selected", _params, socket) do
    Enum.each(socket.assigns.selected_ids, &PendingDecisions.decide(&1, :approve))
    {:noreply, assign(socket, pending: PendingDecisions.list_pending(), selected_ids: MapSet.new())}
  end

  @impl true
  def handle_event("deny_selected", _params, socket) do
    Enum.each(socket.assigns.selected_ids, &PendingDecisions.decide(&1, :deny))
    {:noreply, assign(socket, pending: PendingDecisions.list_pending(), selected_ids: MapSet.new())}
  end

  @impl true
  def handle_event("toggle_settings_modal", _params, socket) do
    {:noreply, assign(socket, show_settings_modal: !socket.assigns.show_settings_modal)}
  end

  @impl true
  def handle_event("toggle_behavior_menu", _params, socket) do
    {:noreply, assign(socket, show_behavior_menu: !socket.assigns.show_behavior_menu)}
  end

  @impl true
  def handle_event("close_behavior_menu", _params, socket) do
    {:noreply, assign(socket, show_behavior_menu: false)}
  end

  @impl true
  def handle_event("set_display_mode", %{"mode" => mode}, socket) do
    new_mode = safe_mode_atom(mode)

    socket =
      socket
      |> assign(:approval_display_mode, new_mode)
      |> assign(:show_behavior_menu, false)
      # If the user switches to a non-modal mode, drop any open modal so the
      # change is not flow-breaking; re-arm the toast for pending items.
      |> assign(:auth_dismissed, new_mode != :always_modal)
      |> push_event("show_toast", %{
        type: "info",
        title: "Approval behavior updated",
        message: display_mode_label(new_mode),
        category: "agentlock"
      })

    Task.start_link(fn -> persist_settings(socket.assigns) end)
    {:noreply, socket}
  end

  # Open the full modal from a click-to-open toast.
  @impl true
  def handle_event("open_approval_modal", _params, socket) do
    {:noreply, assign(socket, auth_dismissed: false, modal_minimized: false)}
  end

  # Approve/deny a specific request from a toast action button.
  @impl true
  def handle_event("toast_decide", %{"id" => request_id, "decision" => decision}, socket) do
    dec = if decision == "approve", do: :approve, else: :deny
    PendingDecisions.decide(request_id, dec)
    pending = PendingDecisions.list_pending()

    {:noreply,
     socket
     |> assign(:pending, pending)
     |> assign(:ttl_remaining, if(pending != [], do: @ttl_max, else: 0))}
  end

  @impl true
  def handle_event("update_setting", params, socket) do
    socket =
      cond do
        Map.has_key?(params, "risk_eval_mode") ->
          assign(socket, :risk_eval_mode, String.to_atom(params["risk_eval_mode"]))

        Map.has_key?(params, "risk_threshold") ->
          assign(socket, :risk_threshold, String.to_integer(params["risk_threshold"]))

        Map.has_key?(params, "timeout_seconds") ->
          assign(socket, :timeout_seconds, String.to_integer(params["timeout_seconds"]))

        Map.has_key?(params, "redaction_mode") ->
          assign(socket, :redaction_mode, String.to_atom(params["redaction_mode"]))

        true ->
          socket
      end

    Task.start_link(fn -> persist_settings(socket.assigns) end)
    {:noreply, socket}
  end

  @impl true
  def handle_event("auth_keydown", %{"key" => "Enter"}, socket) do
    if socket.assigns.pending != [] and not socket.assigns.auth_dismissed do
      [top | _] = socket.assigns.pending
      PendingDecisions.decide(top.request_id, :approve)
      pending = PendingDecisions.list_pending()

      {:noreply,
       socket
       |> assign(:pending, pending)
       |> assign(:ttl_remaining, if(pending != [], do: @ttl_max, else: 0))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("auth_keydown", %{"key" => "Escape"}, socket) do
    if socket.assigns.pending != [] and not socket.assigns.auth_dismissed do
      [top | _] = socket.assigns.pending
      PendingDecisions.decide(top.request_id, :deny)
      pending = PendingDecisions.list_pending()

      {:noreply,
       socket
       |> assign(:pending, pending)
       |> assign(:ttl_remaining, if(pending != [], do: @ttl_max, else: 0))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("auth_keydown", %{"key" => key}, socket) when key in ["d", "D"] do
    if socket.assigns.pending != [] and not socket.assigns.auth_dismissed do
      [top | _] = socket.assigns.pending
      PendingDecisions.decide(top.request_id, :deny)
      pending = PendingDecisions.list_pending()

      {:noreply,
       socket
       |> assign(:pending, pending)
       |> assign(:ttl_remaining, if(pending != [], do: @ttl_max, else: 0))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("auth_keydown", _params, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout
      sidebar_collapsed={@sidebar_collapsed}
      inspector_open={@inspector_open}
      phx-window-keydown="auth_keydown"
    >
      <:sidebar>
        <.sidebar_nav current_path="/govern/authorization" />
      </:sidebar>

      <:topbar>
        <.top_bar project_name="CCEM APM" />
      </:topbar>

      <:main>
        <%!-- Page header --%>
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <h1 style="font-size:20px; font-weight:700; color:var(--ccem-fg); margin:0;">
              Authorization v9
            </h1>
            <.badge tone="iris">AgentLock</.badge>
            <%= if length(@pending) > 0 do %>
              <.badge tone="warning" dot>{length(@pending)} pending</.badge>
            <% end %>
          </div>
          <div style="display:flex; align-items:center; gap:8px;">
            <.btn variant="ghost" size="sm" phx-click="toggle_sidebar">
              {if @sidebar_collapsed, do: "Expand", else: "Collapse"}
            </.btn>
            <.btn variant="ghost" size="sm" phx-click="toggle_inspector">Inspector</.btn>
            <.link navigate="/govern/settings">
              <.btn variant="ghost" size="sm">Settings</.btn>
            </.link>

            <%!-- (...) overflow menu: approval Default behavior --%>
            <div style="position:relative;">
              <.btn variant="ghost" size="sm" phx-click="toggle_behavior_menu">
                &#8943;
              </.btn>
              <%= if @show_behavior_menu do %>
                <div
                  phx-click-away="close_behavior_menu"
                  style="position:absolute; right:0; top:36px; z-index:60; min-width:280px; background:var(--ccem-bg-1); border:1px solid var(--ccem-line); border-radius:8px; box-shadow:0 12px 40px rgba(0,0,0,0.45); padding:8px;"
                >
                  <div style="font-size:11px; font-weight:600; color:var(--ccem-fg-dim); text-transform:uppercase; letter-spacing:0.06em; padding:6px 10px 8px;">
                    Default behavior
                  </div>
                  <%= for {mode, label, desc} <- [
                    {:always_modal, "Always show modal", "Blocking overlay every time"},
                    {:toast_actions, "Toaster with options", "Inline Approve / Deny buttons"},
                    {:toast_click, "Toaster (click to open modal)", "Least interruptive — recommended"}
                  ] do %>
                    <button
                      type="button"
                      phx-click="set_display_mode"
                      phx-value-mode={Atom.to_string(mode)}
                      style={"display:flex; align-items:flex-start; gap:10px; width:100%; text-align:left; background:#{if @approval_display_mode == mode, do: "var(--ccem-bg-2)", else: "transparent"}; border:none; border-radius:6px; padding:8px 10px; cursor:pointer; color:var(--ccem-fg);"}
                    >
                      <span style={"margin-top:2px; width:14px; height:14px; border-radius:50%; border:2px solid #{if @approval_display_mode == mode, do: "var(--ccem-accent, #7c9eff)", else: "var(--ccem-line)"}; flex-shrink:0; display:flex; align-items:center; justify-content:center;"}>
                        <%= if @approval_display_mode == mode do %>
                          <span style="width:6px; height:6px; border-radius:50%; background:var(--ccem-accent, #7c9eff);"></span>
                        <% end %>
                      </span>
                      <span style="display:flex; flex-direction:column; gap:2px;">
                        <span style="font-size:13px; font-weight:500;">{label}</span>
                        <span style="font-size:11px; color:var(--ccem-fg-muted);">{desc}</span>
                      </span>
                    </button>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Stat tiles --%>
        <div style="display:grid; grid-template-columns:repeat(4,1fr); gap:12px; margin-bottom:20px;">
          <.card>
            <.stat_tile label="Active Gates" value={to_string(length(@pending))} />
          </.card>
          <.card>
            <.stat_tile label="Decisions Today" value={to_string(@auth_stats.decisions_today)} />
          </.card>
          <.card>
            <.stat_tile label="Avg TTL" value={"#{@auth_stats.avg_ttl_ms}ms"} />
          </.card>
          <.card>
            <.stat_tile label="Policy Rules" value={to_string(length(@policy_rules))} />
          </.card>
        </div>

        <%!-- TTL countdown gauge — shown only when pending gates exist --%>
        <%= if length(@pending) > 0 do %>
          <.card style="margin-bottom:20px;">
            <div style="display:flex; align-items:center; gap:24px;">
              <div style="display:flex; flex-direction:column; align-items:center; gap:6px;">
                <.gauge value={round(@ttl_remaining / @ttl_max * 100)} size={80} label="TTL" />
                <span style="font-size:11px; color:var(--ccem-fg-dim); font-variant-numeric:tabular-nums;">
                  {@ttl_remaining}s remaining
                </span>
              </div>
              <div style="flex:1; min-width:0;">
                <p style="font-size:13px; font-weight:600; color:var(--ccem-fg); margin:0 0 4px;">
                  {length(@pending)} pending authorization request{if length(@pending) != 1, do: "s", else: ""}
                </p>
                <p style="font-size:12px; color:var(--ccem-fg-muted); margin:0 0 12px;">
                  Approval required before 20-second TTL expires.
                </p>
                <div style="display:flex; gap:8px;">
                  <.btn variant="primary" size="sm" phx-click="approve_all_pending">Approve All</.btn>
                  <.btn variant="destructive" size="sm" phx-click="dismiss_all_pending">Deny All</.btn>
                  <.btn variant="ghost" size="sm" phx-click="dismiss_auth">Dismiss</.btn>
                </div>
              </div>
              <div style="display:flex; flex-direction:column; gap:6px; font-size:11px; color:var(--ccem-fg-dim);">
                <span>
                  <kbd style="background:var(--ccem-bg-2);border:1px solid var(--ccem-line);border-radius:3px;padding:1px 5px;font-family:var(--ccem-font-mono);">&#8629;</kbd>
                  Approve
                </span>
                <span>
                  <kbd style="background:var(--ccem-bg-2);border:1px solid var(--ccem-line);border-radius:3px;padding:1px 5px;font-family:var(--ccem-font-mono);">Esc</kbd>
                  /
                  <kbd style="background:var(--ccem-bg-2);border:1px solid var(--ccem-line);border-radius:3px;padding:1px 5px;font-family:var(--ccem-font-mono);">D</kbd>
                  Deny
                </span>
              </div>
            </div>
          </.card>
        <% end %>

        <%!-- Blocking approval modal — only in :always_modal mode --%>
        <%= if @approval_display_mode == :always_modal and length(@pending) > 0 and not @auth_dismissed do %>
          <% top = List.first(@pending) %>
          <div style="position:fixed; inset:0; z-index:80; background:rgba(8,11,18,0.72); backdrop-filter:blur(4px); display:flex; align-items:center; justify-content:center; padding:24px;">
            <div
              role="dialog"
              aria-modal="true"
              aria-label="AgentLock approval required"
              style="width:100%; max-width:520px; background:var(--ccem-bg-1); border:1px solid var(--ccem-line); border-radius:12px; box-shadow:0 24px 64px rgba(0,0,0,0.55); overflow:hidden;"
            >
              <div style="display:flex; align-items:center; justify-content:space-between; padding:16px 20px; border-bottom:1px solid var(--ccem-line);">
                <div style="display:flex; align-items:center; gap:10px;">
                  <.badge tone="warning" dot>Approval required</.badge>
                  <span style="font-size:13px; color:var(--ccem-fg-muted); font-variant-numeric:tabular-nums;">
                    {@ttl_remaining}s
                  </span>
                </div>
                <.gauge value={round(@ttl_remaining / @ttl_max * 100)} size={44} />
              </div>
              <div style="padding:20px;">
                <p style="font-size:15px; font-weight:600; color:var(--ccem-fg); margin:0 0 6px;">
                  {Map.get(top, :tool_name, "Tool")} requires authorization
                </p>
                <p style="font-size:12px; color:var(--ccem-fg-muted); margin:0 0 16px; font-family:var(--ccem-font-mono);">
                  {Map.get(top, :agent_id, "agent")} · risk {Map.get(top, :risk_level, "n/a")}
                  <%= if length(@pending) > 1 do %>
                    · +{length(@pending) - 1} more queued
                  <% end %>
                </p>
                <div style="display:flex; gap:10px;">
                  <.btn variant="primary" phx-click="approve" phx-value-id={Map.get(top, :request_id)}>
                    Approve &nbsp;<kbd style="opacity:0.7;">&#8629;</kbd>
                  </.btn>
                  <.btn variant="destructive" phx-click="deny" phx-value-id={Map.get(top, :request_id)}>
                    Deny &nbsp;<kbd style="opacity:0.7;">Esc</kbd>
                  </.btn>
                  <div style="flex:1;"></div>
                  <.btn variant="ghost" phx-click="dismiss_auth">Dismiss</.btn>
                </div>
                <p style="font-size:11px; color:var(--ccem-fg-dim); margin:14px 0 0;">
                  <kbd style="background:var(--ccem-bg-2);border:1px solid var(--ccem-line);border-radius:3px;padding:1px 5px;">&#8629;</kbd>
                  Approve ·
                  <kbd style="background:var(--ccem-bg-2);border:1px solid var(--ccem-line);border-radius:3px;padding:1px 5px;">Esc</kbd>
                  /
                  <kbd style="background:var(--ccem-bg-2);border:1px solid var(--ccem-line);border-radius:3px;padding:1px 5px;">D</kbd>
                  Deny · change default via the &#8943; menu
                </p>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Tab navigation --%>
        <div style="margin-bottom:16px;">
          <.segmented_control
            options={["Overview", "Policy Rules", "Pending", "Audit Log"]}
            active={tab_display(@active_tab)}
            on_change="switch_tab_display"
          />
        </div>

        <%!-- Overview tab --%>
        <%= if @active_tab == "overview" do %>
          <div style="display:grid; grid-template-columns:repeat(2,1fr); gap:16px; margin-bottom:20px;">
            <.card>
              <p style="font-size:12px; font-weight:600; color:var(--ccem-fg-dim); text-transform:uppercase; letter-spacing:0.06em; margin:0 0 12px;">
                Auth Summary
              </p>
              <div style="display:grid; grid-template-columns:repeat(2,1fr); gap:12px;">
                <.stat_tile label="Registered Tools" value={to_string(@summary.registered_tools)} />
                <.stat_tile label="Active Sessions" value={to_string(@summary.active_sessions)} />
                <.stat_tile label="Total Granted" value={to_string(@summary.total_authorized)} />
                <.stat_tile label="Total Denied" value={to_string(@summary.total_denied)} />
              </div>
            </.card>

            <.card>
              <p style="font-size:12px; font-weight:600; color:var(--ccem-fg-dim); text-transform:uppercase; letter-spacing:0.06em; margin:0 0 12px;">
                Token Status
              </p>
              <div style="display:flex; flex-direction:column; gap:8px;">
                <div style="display:flex; align-items:center; justify-content:space-between;">
                  <span style="font-size:13px; color:var(--ccem-fg);">Active</span>
                  <.badge tone="success">{Map.get(@summary.tokens || %{}, :active, 0)}</.badge>
                </div>
                <div style="display:flex; align-items:center; justify-content:space-between;">
                  <span style="font-size:13px; color:var(--ccem-fg);">Used</span>
                  <.badge tone="neutral">{Map.get(@summary.tokens || %{}, :used, 0)}</.badge>
                </div>
                <div style="display:flex; align-items:center; justify-content:space-between;">
                  <span style="font-size:13px; color:var(--ccem-fg);">Expired</span>
                  <.badge tone="warning">{Map.get(@summary.tokens || %{}, :expired, 0)}</.badge>
                </div>
              </div>
            </.card>
          </div>

          <%!-- Scope test panel --%>
          <.card>
            <p style="font-size:12px; font-weight:600; color:var(--ccem-fg-dim); text-transform:uppercase; letter-spacing:0.06em; margin:0 0 12px;">
              Scope Test
            </p>
            <div style="display:flex; align-items:flex-end; gap:8px;">
              <div style="flex:1;">
                <label style="display:block; font-size:12px; color:var(--ccem-fg-muted); margin-bottom:4px;">
                  Tool Name
                </label>
                <.ds_input
                  type="text"
                  name="tool_name"
                  placeholder="e.g. Bash, Write, Read"
                  value={@scope_test_input["tool_name"]}
                  phx-change="update_scope_test"
                  phx-value-field="tool_name"
                />
              </div>
              <div style="flex:1;">
                <label style="display:block; font-size:12px; color:var(--ccem-fg-muted); margin-bottom:4px;">
                  Scope (optional)
                </label>
                <.ds_input
                  type="text"
                  name="scope"
                  placeholder="e.g. /path/to/file"
                  value={@scope_test_input["scope"]}
                  phx-change="update_scope_test"
                  phx-value-field="scope"
                />
              </div>
              <.btn variant="primary" size="md" phx-click="test_authorization">
                Test Authorization
              </.btn>
            </div>
            <%= if @scope_test_result do %>
              <div style="margin-top:12px; padding:10px 12px; border-radius:6px; background:var(--ccem-bg-2); display:flex; align-items:center; gap:10px;">
                <.badge tone={@scope_test_result.status}>
                  {String.upcase(to_string(@scope_test_result.status))}
                </.badge>
                <span style="font-size:13px; color:var(--ccem-fg);">{@scope_test_result.message}</span>
              </div>
            <% end %>
          </.card>
        <% end %>

        <%!-- Policy Rules tab --%>
        <%= if @active_tab == "policies" do %>
          <.card padded={false}>
            <.data_table id="policy-rules-table" rows={@policy_rules}>
              <:col :let={rule} label="Tool">
                <span style="font-family:var(--ccem-font-mono); font-size:12px;">{rule.tool_name}</span>
              </:col>
              <:col :let={rule} label="Action">
                <.badge tone={if rule.action == :always_allow, do: "success", else: "error"}>
                  {if rule.action == :always_allow, do: "ALLOW", else: "DENY"}
                </.badge>
              </:col>
              <:col :let={rule} label="Added">
                <span style="font-size:12px; color:var(--ccem-fg-muted);">
                  {relative_time(rule.inserted_at)}
                </span>
              </:col>
              <:col :let={rule} label="Actions">
                <.btn variant="ghost" size="xs" phx-click="remove_rule" phx-value-tool={rule.tool_name}>
                  Remove
                </.btn>
              </:col>
            </.data_table>
            <%= if @policy_rules == [] do %>
              <div style="padding:32px; text-align:center; color:var(--ccem-fg-muted); font-size:13px;">
                No permanent policy rules. Use Approve/Deny with "Always" to add rules.
              </div>
            <% end %>
          </.card>

          <div style="margin-top:20px;">
            <.card padded={false}>
              <div style="padding:12px 16px; border-bottom:1px solid var(--ccem-line-subtle);">
                <p style="font-size:12px; font-weight:600; color:var(--ccem-fg-dim); text-transform:uppercase; letter-spacing:0.06em; margin:0;">
                  Registered Tool Policies
                </p>
              </div>
              <.data_table id="tools-policy-table" rows={@tools}>
                <:col :let={tool} label="Tool">
                  <span style="font-family:var(--ccem-font-mono); font-size:12px;">{tool.name}</span>
                </:col>
                <:col :let={tool} label="Risk">
                  <.badge tone={risk_ds_tone(tool.risk_level)}>{tool.risk_level}</.badge>
                </:col>
                <:col :let={tool} label="Requires Auth">
                  <.badge tone={if tool.requires_auth, do: "warning", else: "success"}>
                    {if tool.requires_auth, do: "Yes", else: "No"}
                  </.badge>
                </:col>
                <:col :let={tool} label="Data Boundary">
                  <span style="font-size:12px; color:var(--ccem-fg-muted);">{tool.data_boundary}</span>
                </:col>
                <:col :let={tool} label="Quick Rules">
                  <div style="display:flex; gap:4px;">
                    <.btn variant="ghost" size="xs" phx-click="always_allow" phx-value-tool={tool.name}>
                      Allow
                    </.btn>
                    <.btn variant="ghost" size="xs" phx-click="always_deny" phx-value-tool={tool.name}>
                      Deny
                    </.btn>
                  </div>
                </:col>
              </.data_table>
            </.card>
          </div>
        <% end %>

        <%!-- Pending tab --%>
        <%= if @active_tab == "pending" do %>
          <%= if @pending == [] do %>
            <.card>
              <div style="padding:32px; text-align:center; color:var(--ccem-fg-muted);">
                <p style="font-size:13px; margin:0 0 4px;">No pending authorization requests</p>
                <p style="font-size:12px; opacity:0.7; margin:0;">
                  High-risk tool calls awaiting approval will appear here
                </p>
              </div>
            </.card>
          <% else %>
            <div style="display:flex; flex-direction:column; gap:8px;">
              <% grouped = group_pending_by_agent(@pending) %>
              <%= for {agent_id, gates} <- grouped do %>
                <% agent_lbl = NamespaceResolver.agent_label(agent_id) %>
                <% max_risk = gates |> Enum.map(& &1.risk_level) |> Enum.max_by(&risk_weight/1) %>
                <.card>
                  <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:12px;">
                    <div style="display:flex; align-items:center; gap:8px;">
                      <span style="font-size:13px; font-weight:600; color:var(--ccem-fg);">{agent_lbl}</span>
                      <.badge tone={risk_ds_tone(max_risk)}>{max_risk}</.badge>
                      <.badge tone="neutral">
                        {length(gates)} request{if length(gates) != 1, do: "s", else: ""}
                      </.badge>
                    </div>
                    <div style="display:flex; gap:4px;">
                      <.btn variant="primary" size="sm" phx-click="approve_group" phx-value-agent={agent_id}>
                        Approve All
                      </.btn>
                      <.btn variant="destructive" size="sm" phx-click="deny_group" phx-value-agent={agent_id}>
                        Deny All
                      </.btn>
                    </div>
                  </div>
                  <div style="display:flex; flex-direction:column; gap:6px;">
                    <%= for gate <- gates do %>
                      <div style="padding:10px 12px; background:var(--ccem-bg-2); border-radius:6px; display:flex; align-items:center; gap:10px;">
                        <div style="flex:1; min-width:0;">
                          <div style="display:flex; align-items:center; gap:6px; margin-bottom:4px;">
                            <.badge tone={action_ds_tone(gate[:action_type])}>
                              {action_type_display(gate[:action_type])}
                            </.badge>
                            <span style="font-family:var(--ccem-font-mono); font-size:12px; font-weight:600; color:var(--ccem-fg);">
                              {gate.tool_name}
                            </span>
                            <.badge tone={risk_ds_tone(gate.risk_level)}>{gate.risk_level}</.badge>
                          </div>
                          <p style="font-size:12px; color:var(--ccem-fg-muted); margin:0;">
                            {describe_tool_action(gate.tool_name, gate.params)}
                          </p>
                        </div>
                        <div style="display:flex; gap:4px; flex-shrink:0;">
                          <.btn variant="primary" size="sm" phx-click="approve_gate" phx-value-id={gate.request_id}>
                            Approve
                          </.btn>
                          <.btn variant="destructive" size="sm" phx-click="deny_gate" phx-value-id={gate.request_id}>
                            Deny
                          </.btn>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </.card>
              <% end %>
            </div>
          <% end %>
        <% end %>

        <%!-- Audit Log tab --%>
        <%= if @active_tab == "audit" do %>
          <.card padded={false}>
            <.data_table id="audit-log-table" rows={Enum.with_index(@decisions)}>
              <:col :let={{decision, _idx}} label="Decision">
                <.badge tone={decision_ds_tone(decision.status)}>
                  {decision_status_label(decision.status)}
                </.badge>
              </:col>
              <:col :let={{decision, _idx}} label="Tool">
                <span style="font-family:var(--ccem-font-mono); font-size:12px;">{decision.tool}</span>
              </:col>
              <:col :let={{decision, _idx}} label="Risk">
                <.badge tone={risk_ds_tone(decision.risk_level)}>{decision.risk_level}</.badge>
              </:col>
              <:col :let={{decision, _idx}} label="Session">
                <span style="font-family:var(--ccem-font-mono); font-size:11px; color:var(--ccem-fg-muted);">
                  {truncate_session(decision.session_id)}
                </span>
              </:col>
              <:col :let={{decision, idx}} label="Time">
                <button
                  style="font-size:12px; color:var(--ccem-fg-muted); background:none; border:none; cursor:pointer; padding:0;"
                  phx-click="select_decision"
                  phx-value-idx={idx}
                >
                  {relative_time(decision.timestamp)}
                </button>
              </:col>
            </.data_table>
            <%= if @decisions == [] do %>
              <div style="padding:32px; text-align:center; color:var(--ccem-fg-muted); font-size:13px;">
                No authorization decisions yet. Waiting for live feed...
              </div>
            <% end %>
          </.card>
        <% end %>
      </:main>

      <:inspector>
        <.inspector_panel open={@inspector_open} mode={@inspector_mode} on_close="toggle_inspector">
          <:selection>
            <%= if @scope_test_result && @inspector_mode == "selection" && @selected_decision == nil do %>
              <div style="padding:8px 0;">
                <p style="font-size:12px; font-weight:600; color:var(--ccem-fg-dim); text-transform:uppercase; letter-spacing:0.06em; margin:0 0 10px;">
                  Test Result
                </p>
                <.badge tone={@scope_test_result.status}>
                  {String.upcase(to_string(@scope_test_result.status))}
                </.badge>
                <p style="font-size:13px; color:var(--ccem-fg); margin:8px 0;">
                  {@scope_test_result.message}
                </p>
                <p style="font-size:12px; color:var(--ccem-fg-muted); margin:0;">
                  Tool:
                  <span style="font-family:var(--ccem-font-mono);">{@scope_test_input["tool_name"]}</span>
                </p>
                <%= if @scope_test_input["scope"] != "" do %>
                  <p style="font-size:12px; color:var(--ccem-fg-muted); margin:4px 0 0;">
                    Scope:
                    <span style="font-family:var(--ccem-font-mono);">{@scope_test_input["scope"]}</span>
                  </p>
                <% end %>
              </div>
            <% end %>
            <%= if @selected_decision && @inspector_mode == "selection" do %>
              <div style="padding:8px 0;">
                <p style="font-size:12px; font-weight:600; color:var(--ccem-fg-dim); text-transform:uppercase; letter-spacing:0.06em; margin:0 0 10px;">
                  Decision Detail
                </p>
                <div style="display:flex; flex-direction:column; gap:8px;">
                  <div>
                    <span style="font-size:11px; color:var(--ccem-fg-dim);">Status</span>
                    <div style="margin-top:4px;">
                      <.badge tone={decision_ds_tone(@selected_decision.status)}>
                        {decision_status_label(@selected_decision.status)}
                      </.badge>
                    </div>
                  </div>
                  <div>
                    <span style="font-size:11px; color:var(--ccem-fg-dim);">Tool</span>
                    <p style="font-family:var(--ccem-font-mono); font-size:13px; color:var(--ccem-fg); margin:4px 0 0;">
                      {@selected_decision.tool}
                    </p>
                  </div>
                  <div>
                    <span style="font-size:11px; color:var(--ccem-fg-dim);">Risk Level</span>
                    <div style="margin-top:4px;">
                      <.badge tone={risk_ds_tone(@selected_decision.risk_level)}>
                        {@selected_decision.risk_level}
                      </.badge>
                    </div>
                  </div>
                  <div>
                    <span style="font-size:11px; color:var(--ccem-fg-dim);">Session</span>
                    <p style="font-family:var(--ccem-font-mono); font-size:12px; color:var(--ccem-fg-muted); margin:4px 0 0; word-break:break-all;">
                      {@selected_decision.session_id}
                    </p>
                  </div>
                  <div>
                    <span style="font-size:11px; color:var(--ccem-fg-dim);">Timestamp</span>
                    <p style="font-size:12px; color:var(--ccem-fg-muted); margin:4px 0 0;">
                      {@selected_decision.timestamp}
                    </p>
                  </div>
                </div>
              </div>
            <% end %>
            <%= if @selected_decision == nil && @scope_test_result == nil do %>
              <p style="font-size:13px; color:var(--ccem-fg-muted); padding:8px 0;">
                Click a decision in the audit log or run a scope test to see details.
              </p>
            <% end %>
          </:selection>
          <:filters>
            <div style="padding:8px 0;">
              <p style="font-size:12px; font-weight:600; color:var(--ccem-fg-dim); text-transform:uppercase; letter-spacing:0.06em; margin:0 0 12px;">
                Filters
              </p>
              <div style="display:flex; flex-direction:column; gap:12px;">
                <div>
                  <label style="display:block; font-size:12px; color:var(--ccem-fg-muted); margin-bottom:4px;">
                    Agent / Tool
                  </label>
                  <.ds_input type="search" placeholder="Filter by name..." />
                </div>
                <div>
                  <label style="font-size:12px; color:var(--ccem-fg-muted); display:block; margin-bottom:6px;">
                    Risk Level
                  </label>
                  <div style="display:flex; flex-wrap:wrap; gap:4px;">
                    <.badge tone="success">None</.badge>
                    <.badge tone="info">Low</.badge>
                    <.badge tone="warning">Medium</.badge>
                    <.badge tone="error">High</.badge>
                    <.badge tone="error">Critical</.badge>
                  </div>
                </div>
                <div>
                  <label style="font-size:12px; color:var(--ccem-fg-muted); display:block; margin-bottom:6px;">
                    Decision
                  </label>
                  <div style="display:flex; gap:4px;">
                    <.badge tone="success">Granted</.badge>
                    <.badge tone="error">Denied</.badge>
                    <.badge tone="warning">Escalated</.badge>
                  </div>
                </div>
                <.toggle on={length(@pending) > 0} label="Show pending only" on_toggle="switch_tab" />
              </div>
            </div>
          </:filters>
        </.inspector_panel>
      </:inspector>
    </.page_layout>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec build_auth_stats(map()) :: map()
  defp build_auth_stats(data) do
    summary = Map.get(data, :summary, %{})
    total = Map.get(summary, :total_authorized, 0) + Map.get(summary, :total_denied, 0)
    avg_ttl = if total > 0, do: div(20_000, max(total, 1)), else: 0
    %{active_gates: 0, decisions_today: total, avg_ttl_ms: avg_ttl}
  end

  defp tab_display("overview"), do: "Overview"
  defp tab_display("policies"), do: "Policy Rules"
  defp tab_display("pending"), do: "Pending"
  defp tab_display("audit"), do: "Audit Log"
  defp tab_display(_), do: "Overview"

  defp risk_ds_tone(:none), do: "success"
  defp risk_ds_tone(:low), do: "info"
  defp risk_ds_tone(:medium), do: "warning"
  defp risk_ds_tone(:high), do: "error"
  defp risk_ds_tone(:critical), do: "error"
  defp risk_ds_tone(_), do: "neutral"

  defp decision_ds_tone(:granted), do: "success"
  defp decision_ds_tone(:denied), do: "error"
  defp decision_ds_tone(:rate_limited), do: "warning"
  defp decision_ds_tone(:escalated), do: "warning"
  defp decision_ds_tone(_), do: "neutral"

  defp action_ds_tone(:destructive), do: "error"
  defp action_ds_tone(:write), do: "warning"
  defp action_ds_tone(:read), do: "info"
  defp action_ds_tone(_), do: "neutral"

  defp auth_summary_default do
    %{
      total_decisions_24h: 0,
      grants: 0,
      denies: 0,
      escalations: 0,
      auto_approvals: 0,
      rate_limited: 0,
      avg_decision_ms: 0,
      pending_count: 0
    }
  end

  defp load_data do
    summary =
      try do
        AuthorizationGate.summary()
      rescue
        _ -> auth_summary_default()
      catch
        :exit, _ -> auth_summary_default()
      end

    sessions = try do SessionStore.list_active() rescue _ -> [] catch :exit, _ -> [] end
    tools = try do AuthorizationGate.list_tools() rescue _ -> [] catch :exit, _ -> [] end

    audit_entries =
      try do
        ApmV5.AuditLog.tail(30)
        |> Enum.filter(fn e ->
          et = Map.get(e, :event_type, "")
          is_binary(et) and String.starts_with?(et, "auth:")
        end)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    %{summary: summary, sessions: sessions, tools: tools, audit_entries: audit_entries}
  end

  defp load_recent_decisions do
    try do
      ApmV5.AuditLog.tail(@max_decisions)
      |> Enum.filter(fn e ->
        et = Map.get(e, :event_type, "")

        is_binary(et) and
          et in [
            "auth:authorization_granted",
            "auth:authorization_denied",
            "auth:authorization_escalated",
            "auth:auto_approval_granted",
            "auth:rate_limited"
          ]
      end)
      |> Enum.map(fn e ->
        status =
          case Map.get(e, :event_type, "") do
            "auth:authorization_granted" -> :granted
            "auth:auto_approval_granted" -> :granted
            "auth:authorization_denied" -> :denied
            "auth:authorization_escalated" -> :escalated
            "auth:rate_limited" -> :rate_limited
            _ -> :unknown
          end

        details = Map.get(e, :details, %{})

        %{
          tool: Map.get(e, :resource, "unknown"),
          status: status,
          risk_level: normalize_risk_level(Map.get(details, :risk_level, "none")),
          session_id: Map.get(details, :session_id, ""),
          timestamp: Map.get(e, :timestamp, DateTime.utc_now() |> DateTime.to_iso8601())
        }
      end)
    rescue
      _ -> []
    end
  end

  defp normalize_risk_level(level) when is_atom(level), do: level
  defp normalize_risk_level("none"), do: :none
  defp normalize_risk_level("low"), do: :low
  defp normalize_risk_level("medium"), do: :medium
  defp normalize_risk_level("high"), do: :high
  defp normalize_risk_level("critical"), do: :critical
  defp normalize_risk_level(_), do: :none

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

  defp describe_tool_action(tool_name, params) when is_map(params) do
    case tool_name do
      "Bash" ->
        cmd = Map.get(params, "command", "")
        if cmd != "", do: "Running: #{String.slice(cmd, 0, 100)}", else: "Executing shell command"

      "Write" ->
        "Writing file: #{Map.get(params, "file_path", "unknown")}"

      "Edit" ->
        path = Map.get(params, "file_path", "unknown")
        old = Map.get(params, "old_string", "")
        "Editing #{path} (#{String.length(old)} chars)"

      "Read" ->
        "Reading file: #{Map.get(params, "file_path", "unknown")}"

      "Glob" ->
        "Searching: #{Map.get(params, "pattern", "*")}"

      "Grep" ->
        "Grep: #{String.slice(Map.get(params, "pattern", ""), 0, 80)}"

      "Agent" ->
        type = Map.get(params, "subagent_type", "general-purpose")
        desc = Map.get(params, "description", Map.get(params, "prompt", ""))
        "Launching #{type} agent: #{String.slice(desc, 0, 80)}"

      "Skill" ->
        "Invoking skill: /#{Map.get(params, "skill", "unknown")}"

      "WebFetch" ->
        "Fetching: #{String.slice(Map.get(params, "url", "unknown"), 0, 80)}"

      _ ->
        desc = Map.get(params, "description", "")
        if desc != "", do: desc, else: "#{tool_name} operation"
    end
  end

  defp describe_tool_action(tool_name, _), do: "#{tool_name} operation"

  defp decision_status_label(:granted), do: "GRANTED"
  defp decision_status_label(:denied), do: "DENIED"
  defp decision_status_label(:rate_limited), do: "RATE LIMITED"
  defp decision_status_label(:escalated), do: "ESCALATED"
  defp decision_status_label(other), do: other |> to_string() |> String.upcase()

  defp truncate_session(""), do: "—"
  defp truncate_session(nil), do: "—"

  defp truncate_session(id) when byte_size(id) > 12 do
    String.slice(id, 0..11) <> "…"
  end

  defp truncate_session(id), do: id

  defp relative_time(nil), do: ""

  defp relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> "#{div(diff, 3600)}h ago"
    end
  end

  defp relative_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> relative_time(dt)
      _ -> ""
    end
  end

  defp relative_time(_), do: ""

  defp persist_settings(assigns) do
    settings = %{
      risk_eval_mode: assigns.risk_eval_mode,
      risk_threshold: assigns.risk_threshold,
      timeout_seconds: assigns.timeout_seconds,
      redaction_mode: assigns.redaction_mode,
      approval_display_mode: assigns.approval_display_mode
    }

    try do
      config_path = Path.expand("~/Developer/ccem/apm/apm_config.json")

      case File.read(config_path) do
        {:ok, content} ->
          updated = content |> Jason.decode!() |> Map.put("agentlock_settings", settings)
          File.write!(config_path, Jason.encode!(updated, pretty: true))
          Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:settings", {:settings_updated, settings})

        _ ->
          :ok
      end
    rescue
      _ -> :ok
    end
  end

  # Approval surface preference. Default is :toast_click (least flow-breaking) —
  # an always-on modal interrupts the user's work, so it is opt-in.
  #   :always_modal  — full blocking modal overlay every time
  #   :toast_actions — corner toaster with inline Approve/Deny buttons
  #   :toast_click   — corner toaster; click it to open the modal (DEFAULT)
  @valid_display_modes [:always_modal, :toast_actions, :toast_click]
  @default_display_mode :toast_click

  defp load_persisted_display_mode do
    try do
      config_path = Path.expand("~/Developer/ccem/apm/apm_config.json")

      with {:ok, content} <- File.read(config_path),
           {:ok, json} <- Jason.decode(content),
           %{"agentlock_settings" => %{"approval_display_mode" => mode}} <- json,
           atom <- safe_mode_atom(mode) do
        atom
      else
        _ -> @default_display_mode
      end
    rescue
      _ -> @default_display_mode
    end
  end

  defp safe_mode_atom(mode) when is_binary(mode) do
    case mode do
      "always_modal" -> :always_modal
      "toast_actions" -> :toast_actions
      "toast_click" -> :toast_click
      _ -> @default_display_mode
    end
  end

  defp safe_mode_atom(mode) when is_atom(mode) do
    if mode in @valid_display_modes, do: mode, else: @default_display_mode
  end

  defp safe_mode_atom(_), do: @default_display_mode

  defp display_mode_label(:always_modal), do: "Always show modal"
  defp display_mode_label(:toast_actions), do: "Toaster with Approve/Deny buttons"
  defp display_mode_label(:toast_click), do: "Toaster (click to open modal)"
  defp display_mode_label(_), do: "Toaster (click to open modal)"

  defp top_pending_request_id([%{request_id: rid} | _]), do: rid
  defp top_pending_request_id(_), do: nil
end
