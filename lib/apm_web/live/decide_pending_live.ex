defmodule ApmWeb.DecidePendingLive do
  @moduledoc """
  v11 Gold Standard — `/decide/pending`

  Unified approvals + authorizations queue (Phase 2, US-GOLD-1).

  Replaces and supersedes:
    - `/approvals`         → 301 to `/decide/pending`
    - `/approvals-history` → 301 to `/decide/pending?status=resolved`

  ## Design spec
  - `design-intake/v11.0.0/from-designer/DESIGN-Decide.md`
  - `handoff-claude-code/03-CONTROLLER-WIRING.md` § Decide.PendingLive
  - Template: `queue_page` (Tier 5)

  ## Keyboard contract (from DESIGN-Decide.md)
    ↑ / k   → move selection up
    ↓ / j   → move selection down
    Enter   → allow selected
    D / Esc → deny selected

  ## PubSub
  Subscribes to `"agentlock:pending"` on connect — other sessions push here.
  A 5s periodic refresh also keeps the queue fresh if PubSub is quiet.

  ## Assigns
  - `:queue`         — list of normalised pending items
  - `:selected`      — currently-keyboard-selected item id or nil
  - `:decide_modal`  — nil | :ask — shows the "Ask…" DecisionModal
  - `:modal_item`    — the item being modal-decided, or nil
  - `:filter`        — "all" | "auth" | "approval" (left-rail filter)
  - `:toast`         — nil | %{tone, title, body} — ephemeral
  - `:status`        — :loading | :live | :error
  - `:sidebar_collapsed` — boolean for page_shell
  """

  use ApmWeb, :live_view

  alias Apm.Decisions
  alias Apm.Auth.PolicyRulesStore

  # v11 Tier-5 templates (no conflict with DesignSystem — new names)
  alias ApmWeb.Components.Templates.PageShell
  alias ApmWeb.Components.Templates.QueuePage
  # v11 Tier-2 composite (no conflict — new names)
  alias ApmWeb.Components.Composite.PageHeader
  alias ApmWeb.Components.Composite.Segmented
  # v11 Tier-4 feedback components (no conflict — new names)
  alias ApmWeb.Components.Feedback.EmptyState
  alias ApmWeb.Components.Feedback.ErrorInline
  alias ApmWeb.Components.Feedback.CountdownRing
  alias ApmWeb.Components.Feedback.SwipeCard
  alias ApmWeb.Components.Feedback.Modal
  alias ApmWeb.Components.Feedback.Toast
  # v11 Core — use fully-qualified to avoid ambiguity with DesignSystem.badge/card/stat_tile
  alias ApmWeb.Components.Core.Badge, as: CoreBadge
  alias ApmWeb.Components.Core.Button, as: CoreButton
  alias ApmWeb.Components.Composite.StatTile

  @pubsub_topic "agentlock:pending"
  @refresh_ms 5_000

  @impl true
  def mount(params, _session, socket) do
    status_filter = if params["status"] == "resolved", do: "resolved", else: "all"

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Apm.PubSub, @pubsub_topic)
      schedule_refresh()
    end

    {:ok,
     socket
     |> assign(:page_title, "Pending Decisions")
     |> assign(:sidebar_collapsed, false)
     |> assign(:filter, status_filter)
     |> assign(:selected, nil)
     |> assign(:decide_modal, nil)
     |> assign(:modal_item, nil)
     |> assign(:modal_decision, "allow")
     |> assign(:sticky_rule, false)
     |> assign(:toast, nil)
     |> assign(:status, :loading)
     |> load_queue()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, load_queue(socket)}
  end

  def handle_info({:agentlock_pending, _}, socket) do
    {:noreply, load_queue(socket)}
  end

  def handle_info({:approval_pending, _}, socket) do
    {:noreply, load_queue(socket)}
  end

  def handle_info({:approval_decided, _}, socket) do
    {:noreply, load_queue(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Keyboard navigation ────────────────────────────────────────────────────

  @impl true
  def handle_event("key_nav", %{"key" => key}, socket) do
    socket =
      case key do
        k when k in ["ArrowDown", "j"] -> move_selection(socket, :next)
        k when k in ["ArrowUp", "k"] -> move_selection(socket, :prev)
        "Enter" -> allow_selected(socket)
        k when k in ["d", "D", "Escape"] -> deny_selected(socket)
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected, id)}
  end

  # ── Decision actions ────────────────────────────────────────────────────────

  def handle_event("swipe_decide", %{"id" => id, "decision" => decision}, socket) do
    do_decide(socket, id, String.to_atom(decision))
  end

  def handle_event("decide", %{"id" => id, "decision" => decision}, socket) do
    do_decide(socket, id, String.to_atom(decision))
  end

  def handle_event("open_ask_modal", %{"id" => id}, socket) do
    item = Enum.find(socket.assigns.queue, &(&1.id == id))
    {:noreply, socket |> assign(:decide_modal, :ask) |> assign(:modal_item, item)}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:decide_modal, nil)
     |> assign(:modal_item, nil)
     |> assign(:modal_decision, "allow")
     |> assign(:sticky_rule, false)}
  end

  def handle_event("toggle_sticky", _params, socket) do
    {:noreply, update(socket, :sticky_rule, &(!&1))}
  end

  def handle_event("modal_select_decision", %{"value" => value}, socket) do
    {:noreply, assign(socket, :modal_decision, value)}
  end

  def handle_event("modal_decide", %{"decision" => decision} = params, socket) do
    id = get_in(socket.assigns, [:modal_item, :id])
    item = socket.assigns.modal_item
    sticky = params["sticky"] == "true"

    socket =
      socket
      |> assign(:sticky_rule, sticky)
      |> assign(:decide_modal, nil)
      |> assign(:modal_item, nil)
      |> assign(:modal_decision, "allow")
      |> maybe_add_sticky_rule(item, decision, sticky)

    if id do
      do_decide(socket, id, String.to_atom(decision))
      |> elem(1)
      |> then(&{:noreply, &1})
    else
      {:noreply, socket}
    end
  end

  def handle_event("approve_all", _params, socket) do
    ids = Enum.map(socket.assigns.queue, & &1.id)
    results = Enum.map(ids, &Decisions.decide(&1, :allow, kind: :auth))
    ok_count = Enum.count(results, &match?({:ok, _}, &1))

    {:noreply,
     socket
     |> push_toast("success", "#{ok_count} decisions cleared", nil)
     |> load_queue()}
  end

  # ── Filter rail ─────────────────────────────────────────────────────────────

  def handle_event("set_filter", %{"value" => filter}, socket) do
    {:noreply, assign(socket, :filter, filter)}
  end

  # ── Sidebar ─────────────────────────────────────────────────────────────────

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, update(socket, :sidebar_collapsed, &(!&1))}
  end

  def handle_event("navigate", %{"id" => id}, socket) do
    path = nav_path(id)
    {:noreply, push_navigate(socket, to: path)}
  end

  def handle_event("open_cmd_k", _params, socket), do: {:noreply, socket}
  def handle_event("open_notifications", _params, socket), do: {:noreply, socket}
  def handle_event("open_project_switcher", _params, socket), do: {:noreply, socket}

  # ── Render ───────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <PageShell.page_shell
      active="pending"
      pending={length(@queue)}
      sidebar_collapsed={@sidebar_collapsed}
    >
      <QueuePage.queue_page
        selected_id={@selected}
        show_inspector={false}
      >
        <:filter_rail>
          <div class="apm-filter-rail">
            <div class="apm-filter-rail__header apm-mono apm-upper">Filter</div>

            <Segmented.segmented
              options={[
                %{value: "all", label: "All"},
                %{value: "auth", label: "Auth"},
                %{value: "approval", label: "Approvals"},
                %{value: "resolved", label: "Resolved"}
              ]}
              value={@filter}
              size="sm"
              on_change="set_filter"
            />

            <div class="apm-filter-rail__counts">
              <StatTile.stat_tile label="Pending" value={to_string(length(@queue))} />
            </div>

            <%= if length(@queue) >= 5 do %>
              <div class="apm-filter-rail__actions">
                <CoreButton.button variant="primary" phx-click="approve_all">
                  Approve All ({length(@queue)})
                </CoreButton.button>
              </div>
            <% end %>
          </div>
        </:filter_rail>

        <:list>
          <div
            class="apm-queue-list"
            phx-keydown="key_nav"
            tabindex="0"
            aria-label="Pending decisions queue"
          >
            <PageHeader.page_header
              title="Pending Decisions"
              breadcrumb={"decide / pending · #{length(@queue)} item#{if length(@queue) != 1, do: "s", else: ""}"}
            />

            <div class="apm-queue-list__body">
              <%= case @status do %>
                <% :loading -> %>
                  <EmptyState.empty_state
                    icon="clock"
                    title="Loading queue…"
                    body="Fetching pending decisions from APM."
                  />
                <% :error -> %>
                  <ErrorInline.error_inline
                    error="Could not load pending decisions."
                    retry="refresh"
                  />
                <% :live -> %>
                  <%= if @queue == [] do %>
                    <EmptyState.empty_state
                      icon="check"
                      title="Queue clear"
                      body="No pending decisions. Use ↑↓ / j k to navigate; Enter to allow; D or Esc to deny."
                    >
                      <:action>
                        <CoreButton.button variant="ghost" phx-click="navigate" phx-value-id="policies">
                          View policies →
                        </CoreButton.button>
                      </:action>
                    </EmptyState.empty_state>
                  <% else %>
                    <%= for item <- visible_queue(assigns) do %>
                      <SwipeCard.swipe_card
                        id={"swipe-#{item.id}"}
                        decision_id={item.id}
                        on_decide="swipe_decide"
                      >
                        <div
                          class={[
                            "apm-pending-card",
                            @selected == item.id && "apm-pending-card--selected"
                          ]}
                          phx-click="select"
                          phx-value-id={item.id}
                        >
                          <div class="apm-pending-card__header">
                            <CountdownRing.countdown_ring
                              id={"ring-#{item.id}"}
                              seconds={item.ttl_s}
                              size={34}
                            />
                            <div class="apm-pending-card__meta">
                              <span class="apm-pending-card__tool apm-mono">{item.tool_name}</span>
                              <CoreBadge.badge tone={risk_tone(item.risk_level)}>
                                {risk_label(item.risk_level)}
                              </CoreBadge.badge>
                            </div>
                          </div>

                          <div class="apm-pending-card__body">
                            <div class="apm-pending-card__subject apm-mono">{item.subject}</div>
                            <div class="apm-pending-card__command">{item.command}</div>
                            <%= if item.reason do %>
                              <div class="apm-pending-card__reason">{item.reason}</div>
                            <% end %>
                          </div>

                          <div class="apm-pending-card__footer">
                            <%= if item.scope do %>
                              <CoreBadge.badge tone="neutral">{item.scope}</CoreBadge.badge>
                            <% end %>
                            <div class="apm-pending-card__actions">
                              <CoreButton.button
                                variant="danger"
                                size="sm"
                                phx-click="decide"
                                phx-value-id={item.id}
                                phx-value-decision="deny"
                              >Deny</CoreButton.button>
                              <CoreButton.button
                                variant="ghost"
                                size="sm"
                                phx-click="open_ask_modal"
                                phx-value-id={item.id}
                              >Ask…</CoreButton.button>
                              <CoreButton.button
                                variant="primary"
                                size="sm"
                                phx-click="decide"
                                phx-value-id={item.id}
                                phx-value-decision="allow"
                              >Allow</CoreButton.button>
                            </div>
                          </div>
                        </div>
                      </SwipeCard.swipe_card>
                    <% end %>
                  <% end %>
              <% end %>
            </div>
          </div>
        </:list>
      </QueuePage.queue_page>
    </PageShell.page_shell>

    <%!-- DecisionModal: Allow / Allow 5min / Always / Deny + sticky-policy-rule toggle --%>
    <%= if @decide_modal == :ask && @modal_item do %>
      <Modal.modal
        id="decision-modal"
        title="Choose policy"
        kicker="Ask…"
        width={520}
        on_close="close_modal"
      >
        <div class="apm-decision-modal">
          <div class="apm-decision-modal__item-info">
            <span class="apm-mono">{@modal_item.tool_name}</span>
            <CoreBadge.badge tone={risk_tone(@modal_item.risk_level)}>
              {risk_label(@modal_item.risk_level)}
            </CoreBadge.badge>
          </div>

          <div class="apm-decision-modal__options">
            <Segmented.segmented
              options={[
                %{value: "allow", label: "Allow"},
                %{value: "allow_5min", label: "Allow 5 min"},
                %{value: "always", label: "Always"},
                %{value: "deny", label: "Deny"}
              ]}
              value="allow"
              on_change="modal_select_decision"
            />
          </div>

          <div class="apm-decision-modal__sticky-toggle">
            <label class="apm-toggle-label">
              <input type="checkbox" phx-click="toggle_sticky" />
              Create sticky policy rule
            </label>
            <div class="apm-decision-modal__rule-preview apm-mono">
              allow {@modal_item.tool_name} where scope = {@modal_item.scope || "*"}
            </div>
          </div>
        </div>
        <:footer>
          <CoreButton.button variant="ghost" phx-click="close_modal">Cancel</CoreButton.button>
          <CoreButton.button
            variant="danger"
            phx-click="modal_decide"
            phx-value-decision="deny"
            phx-value-sticky={to_string(@sticky_rule)}
          >Deny</CoreButton.button>
          <CoreButton.button
            variant="primary"
            phx-click="modal_decide"
            phx-value-decision="allow"
            phx-value-sticky={to_string(@sticky_rule)}
          >Allow</CoreButton.button>
        </:footer>
      </Modal.modal>
    <% end %>

    <%!-- Toast notifications --%>
    <%= if @toast do %>
      <div class="apm-toast-region" role="status" aria-live="polite" style="position:fixed;bottom:24px;right:24px;z-index:300">
        <Toast.toast
          id="decision-toast"
          tone={@toast.tone}
          title={@toast.title}
          body={@toast.body}
        />
      </div>
    <% end %>
    """
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  # Persists a sticky policy rule when the user checks "Create sticky policy rule"
  # in the DecisionModal. The rule targets the specific agent_id (stored as the ETS
  # key) so future requests from that agent are auto-decided without interruption.
  #
  # PolicyRulesStore supports agent-scoped keys via add_rule/3 — we use the agent_id
  # as the tool scope key with `created_by: "decide_pending_modal"` for auditability.
  defp maybe_add_sticky_rule(socket, _item, _decision, false), do: socket

  defp maybe_add_sticky_rule(socket, nil, _decision, true), do: socket

  defp maybe_add_sticky_rule(socket, item, decision, true) do
    action =
      case decision do
        "allow" -> :always_allow
        "deny" -> :always_deny
        _ -> nil
      end

    if action do
      # Use the agent_id as the key so the rule targets this specific agent.
      # Fall back to tool_name if agent_id is absent (older queue item shape).
      rule_key = item[:agent_id] || item[:tool_name] || "*"

      PolicyRulesStore.add_rule(rule_key, action,
        created_by: "decide_pending_modal",
        approved_by: nil
      )
    end

    socket
  end

  defp load_queue(socket) do
    try do
      queue = Decisions.pending(limit: 100)

      socket
      |> assign(:queue, queue)
      |> assign(:status, :live)
    rescue
      e ->
        require Logger
        Logger.error("[DecidePendingLive] load_queue failed: #{inspect(e)}")
        socket |> assign(:queue, []) |> assign(:status, :error)
    end
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  defp do_decide(socket, id, decision) when decision in [:allow, :deny] do
    item = Enum.find(socket.assigns.queue, &(&1.id == id))
    kind = if item, do: item.kind, else: :auth

    result = Decisions.decide(id, decision, kind: kind)

    socket =
      case result do
        {:ok, _} ->
          tone = if decision == :allow, do: "success", else: "error"
          label = if decision == :allow, do: "allow", else: "deny"

          socket
          |> push_toast(tone, "Decision recorded — #{label}", nil)
          |> load_queue()
          |> advance_selection(id)

        {:error, reason} ->
          push_toast(socket, "error", "Decision failed", inspect(reason))
      end

    {:noreply, socket}
  end

  defp allow_selected(socket) do
    case socket.assigns.selected do
      nil ->
        socket

      id ->
        {_, socket} = do_decide(socket, id, :allow)
        socket
    end
  end

  defp deny_selected(socket) do
    case socket.assigns.selected do
      nil ->
        socket

      id ->
        {_, socket} = do_decide(socket, id, :deny)
        socket
    end
  end

  defp move_selection(socket, direction) do
    queue = socket.assigns.queue
    selected = socket.assigns.selected

    case queue do
      [] ->
        socket

      items ->
        ids = Enum.map(items, & &1.id)
        current_idx = Enum.find_index(ids, &(&1 == selected)) || -1

        new_idx =
          case direction do
            :next -> min(current_idx + 1, length(ids) - 1)
            :prev -> max(current_idx - 1, 0)
          end

        assign(socket, :selected, Enum.at(ids, new_idx))
    end
  end

  defp advance_selection(socket, decided_id) do
    queue = socket.assigns.queue
    ids = Enum.map(queue, & &1.id)
    current_idx = Enum.find_index(ids, &(&1 == decided_id)) || 0

    # After deciding, select the item that was below, or the last item
    next_id =
      cond do
        current_idx < length(ids) -> Enum.at(ids, current_idx)
        length(ids) > 0 -> List.last(ids)
        true -> nil
      end

    assign(socket, :selected, next_id)
  end

  defp visible_queue(assigns) do
    queue = assigns.queue

    case assigns.filter do
      "auth" -> Enum.filter(queue, &(&1.kind == :auth))
      "approval" -> Enum.filter(queue, &(&1.kind == :approval))
      _ -> queue
    end
  end

  defp push_toast(socket, tone, title, body) do
    assign(socket, :toast, %{tone: tone, title: title, body: body})
  end

  defp risk_tone(:critical), do: "error"
  defp risk_tone(:high), do: "warning"
  defp risk_tone(_), do: "neutral"

  defp risk_label(:critical), do: "critical"
  defp risk_label(:high), do: "high"
  defp risk_label(_), do: "low"

  defp nav_path("pending"), do: "/decide/pending"
  defp nav_path("policies"), do: "/decide/policies"
  defp nav_path("upm-gates"), do: "/decide/upm"
  defp nav_path("playground"), do: "/decide/test"
  defp nav_path("dashboard"), do: "/"
  defp nav_path("fleet"), do: "/live/fleet"
  defp nav_path("health"), do: "/operate/health"
  defp nav_path(id), do: "/#{id}"
end
