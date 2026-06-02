defmodule ApmWeb.InvestigateSessionLive do
  @moduledoc """
  v11 Gold Standard — `/investigate/sessions/:id`

  Forensic session detail with tool-call trace + audit cross-ref + inspector drawer.
  (Phase 2, US-GOLD-2).

  Supersedes `/sessions/:id` and `/observe/sessions/:session_id` → 301 redirects
  to `/investigate/sessions/:id`.

  ## Design spec
  - `design-intake/v11.0.0/from-designer/DESIGN-Investigate.md`
  - `handoff-claude-code/03-CONTROLLER-WIRING.md` § Investigate.SessionLive
  - Template: `detail_page` + `split_view` (timeline left, drawer right)

  ## Layout
  ```
  page_shell
  └── detail_page
      ├── header: page_header (breadcrumb + metric strip + status badge)
      ├── body:   split_view
      │           ├── master: timeline of tool calls (chat transcript rows)
      │           └── detail: drawer/inspector for selected tool call
      └── footer: (optional actions)
  ```

  ## Assigns
  - `:session`        — map or nil (loaded from Apm.Sessions)
  - `:metrics`        — %{duration_s, tokens_in, tokens_out, tool_calls, cost_usd}
  - `:tool_calls`     — list of normalised tool-call maps
  - `:selected_call`  — currently-open tool call id or nil (drives drawer)
  - `:audit_entries`  — list of audit entries for the selected tool call
  - `:breaker_open`   — boolean: show circuit-breaker banner
  - `:transcript`     — list of message maps (role, content, tool_calls)
  - `:loading`        — boolean
  - `:error`          — String.t() | nil
  - `:sidebar_collapsed` — boolean
  """

  use ApmWeb, :live_view

  alias Apm.Sessions
  alias Apm.ToolCalls

  # v11 Tier-5 templates
  alias ApmWeb.Components.Templates.PageShell
  alias ApmWeb.Components.Templates.DetailPage
  alias ApmWeb.Components.Templates.SplitView
  # v11 Tier-2 composite
  alias ApmWeb.Components.Composite.PageHeader
  alias ApmWeb.Components.Composite.StatTile
  # v11 Tier-3 data
  alias ApmWeb.Components.Data.Timeline
  alias ApmWeb.Components.Data.JsonViewer
  alias ApmWeb.Components.Data.Sparkline
  # v11 Tier-4 feedback
  alias ApmWeb.Components.Feedback.EmptyState
  alias ApmWeb.Components.Feedback.ErrorInline
  alias ApmWeb.Components.Feedback.Drawer
  alias ApmWeb.Components.Feedback.Modal
  # v11 Core — aliased to avoid DesignSystem ambiguity
  alias ApmWeb.Components.Core.Badge, as: CoreBadge
  alias ApmWeb.Components.Core.Button, as: CoreButton
  alias ApmWeb.Components.Core.Skeleton

  @refresh_ms 15_000

  @impl true
  def mount(%{"id" => session_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Apm.PubSub, Sessions.session_topic(session_id))
      Phoenix.PubSub.subscribe(Apm.PubSub, Sessions.pubsub_topic())
      schedule_refresh()
    end

    {:ok,
     socket
     |> assign(:session_id, session_id)
     |> assign(:session, nil)
     |> assign(:metrics, empty_metrics())
     |> assign(:tool_calls, [])
     |> assign(:selected_call, nil)
     |> assign(:audit_entries, [])
     |> assign(:breaker_open, false)
     |> assign(:transcript, [])
     |> assign(:loading, true)
     |> assign(:error, nil)
     |> assign(:sidebar_collapsed, false)
     |> assign(:confirm_breaker, false)
     |> load_session(session_id)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, load_session(socket, socket.assigns.session_id)}
  end

  def handle_info({:sessions_updated, _sessions}, socket) do
    {:noreply, load_session(socket, socket.assigns.session_id)}
  end

  def handle_info({:tool_call_update, _}, socket) do
    {:noreply, load_tool_calls(socket, socket.assigns.session_id)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Events ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("open_tool_call", %{"id" => id}, socket) do
    audit = ToolCalls.audit_for(id)

    {:noreply,
     socket
     |> assign(:selected_call, id)
     |> assign(:audit_entries, audit)}
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, socket |> assign(:selected_call, nil) |> assign(:audit_entries, [])}
  end

  def handle_event("close_breaker_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm_breaker, true)}
  end

  def handle_event("close_breaker", _params, socket) do
    # POST /api/v2/circuit-breaker/close — fire and forget
    Task.start(fn ->
      try do
        :httpc.request(:post, {~c"http://localhost:3032/api/v2/circuit-breaker/close", [], ~c"application/json", ~c"{}"}, [], [])
      rescue
        _ -> :ok
      end
    end)

    {:noreply,
     socket
     |> assign(:breaker_open, false)
     |> assign(:confirm_breaker, false)}
  end

  def handle_event("cancel_close_breaker", _params, socket) do
    {:noreply, assign(socket, :confirm_breaker, false)}
  end

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
  def handle_event("retry", _params, socket) do
    {:noreply, load_session(socket, socket.assigns.session_id)}
  end

  # ── Render ───────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    {timeline_lanes, timeline_events} = ToolCalls.to_timeline(assigns.tool_calls)
    timeline_start_ms = first_call_ms(assigns.tool_calls)
    timeline_window_ms = timeline_window(assigns.tool_calls)

    assigns =
      assigns
      |> Map.put(:timeline_lanes, timeline_lanes)
      |> Map.put(:timeline_events, timeline_events)
      |> Map.put(:timeline_start_ms, timeline_start_ms)
      |> Map.put(:timeline_window_ms, timeline_window_ms)
      |> Map.put(:selected_call_data, find_call(assigns.tool_calls, assigns.selected_call))

    ~H"""
    <PageShell.page_shell
      active="inv-sessions"
      pending={0}
      sidebar_collapsed={@sidebar_collapsed}
    >
      <DetailPage.detail_page>
        <:header>
          <PageHeader.page_header
            title={session_title(@session, @session_id)}
            breadcrumb={"investigate / sessions / #{truncate(@session_id, 12)}"}
            tabs={[
              %{id: "timeline", label: "Tool Call Timeline"},
              %{id: "audit", label: "Audit Trail"}
            ]}
            active_tab="timeline"
          >
            <:badge>
              <CoreBadge.badge tone={session_status_tone(@session)}>
                {session_status_label(@session)}
              </CoreBadge.badge>
            </:badge>
            <:actions>
              <CoreButton.button variant="ghost" size="sm" phx-click="navigate" phx-value-id="inv-audit">
                Audit trail →
              </CoreButton.button>
              <CoreButton.button variant="outline" size="sm">
                Open JSONL
              </CoreButton.button>
            </:actions>
          </PageHeader.page_header>

          <%!-- 5-up metric strip --%>
          <div class="apm-metric-strip" style="display:flex;gap:8px;padding:12px 20px">
            <StatTile.stat_tile
              label="Duration"
              value={format_duration(@metrics.duration_s)}
            />
            <StatTile.stat_tile
              label="Tokens in"
              value={to_string(@metrics.tokens_in)}
              count_up={true}
            />
            <StatTile.stat_tile
              label="Tokens out"
              value={to_string(@metrics.tokens_out)}
              count_up={true}
            />
            <StatTile.stat_tile
              label="Tool calls"
              value={to_string(@metrics.tool_calls)}
            />
            <StatTile.stat_tile
              label="Cost"
              value={format_cost(@metrics.cost_usd)}
              unit={if @metrics.cost_usd, do: "USD", else: nil}
            />
          </div>

          <%!-- Circuit-breaker banner (when open) --%>
          <%= if @breaker_open do %>
            <div class="apm-cb-banner apm-status-error-soft apm-cb-trace" style="padding:10px 20px;display:flex;align-items:center;gap:12px;border:1px solid var(--apm-status-error)">
              <span style="color:var(--apm-status-error);font-size:13px;font-weight:500">Circuit breaker open</span>
              <CoreButton.button variant="danger" size="sm" phx-click="close_breaker_confirm">
                Close breaker
              </CoreButton.button>
            </div>
          <% end %>
        </:header>

        <:body>
          <%= if @loading do %>
            <div style="padding:24px">
              <Skeleton.skeleton_rows count={8} cols={4} />
            </div>
          <% else %>
            <%= if @error do %>
              <div style="padding:24px">
                <ErrorInline.error_inline error={@error} retry="retry" />
              </div>
            <% else %>
              <SplitView.split_view
                master_width={560}
                selected_id={@selected_call}
              >
                <:master>
                  <div class="apm-session-transcript apm-scroll" style="padding:16px">
                    <%!-- Tool-call timeline (Tier-3 data component) --%>
                    <Timeline.timeline
                      id="session-timeline"
                      lanes={@timeline_lanes}
                      events={@timeline_events}
                      start_ms={@timeline_start_ms}
                      window_ms={@timeline_window_ms}
                    >
                      <:empty>
                        <EmptyState.empty_state
                          icon="term"
                          title="Session has no tool calls."
                          body="This session has not recorded any tool calls yet."
                        />
                      </:empty>
                      <:loading>
                        <Skeleton.skeleton_rows count={6} cols={3} />
                      </:loading>
                      <:error>
                        <ErrorInline.error_inline error="Failed to load tool calls." retry="retry" />
                      </:error>
                    </Timeline.timeline>

                    <%!-- Tool-call rows (chat transcript view) --%>
                    <div class="apm-tool-call-rows" style="margin-top:16px">
                      <%= for tc <- @tool_calls do %>
                        <div
                          class={[
                            "apm-tool-call-row",
                            @selected_call == tc[:id] && "apm-tool-call-row--active"
                          ]}
                          phx-click="open_tool_call"
                          phx-value-id={tc[:id]}
                          style="display:flex;align-items:flex-start;gap:10px;padding:8px 12px;cursor:pointer;border-radius:var(--apm-r-sm);transition:background 120ms"
                        >
                          <CoreBadge.badge tone={status_tone(tc[:status])}>
                            {tc[:tool_name] || "unknown"}
                          </CoreBadge.badge>

                          <div style="flex:1;min-width:0">
                            <div class="apm-mono" style="font-size:11.5px;color:var(--apm-text-muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis">
                              {truncate_args(tc[:args])}
                            </div>
                            <%= if tc[:duration_ms] do %>
                              <div style="font-size:10.5px;color:var(--apm-text-faint)">
                                {tc[:duration_ms]}ms
                              </div>
                            <% end %>
                          </div>

                          <%!-- Per-tool latency sparkline --%>
                          <Sparkline.sparkline
                            data={tc_latency_data(tc)}
                            height={18}
                            color="var(--apm-accent)"
                            fill={false}
                          />
                        </div>
                      <% end %>
                    </div>
                  </div>
                </:master>

                <:detail>
                  <%!-- Tool-call inspector drawer --%>
                  <Drawer.drawer
                    id="tool-call-inspector"
                    variant="inspector"
                    width={440}
                    kicker="Tool Call"
                    title={get_in(@selected_call_data, [:tool_name]) || "Inspector"}
                    on_close="close_drawer"
                  >
                    <%= if @selected_call_data do %>
                      <div style="display:flex;flex-direction:column;gap:16px">
                        <%!-- Status + duration --%>
                        <div style="display:flex;gap:8px;align-items:center">
                          <CoreBadge.badge tone={status_tone(@selected_call_data[:status])}>
                            {call_status_label(@selected_call_data[:status])}
                          </CoreBadge.badge>
                          <%= if @selected_call_data[:duration_ms] do %>
                            <span class="apm-mono" style="font-size:11px;color:var(--apm-text-dim)">
                              {@selected_call_data[:duration_ms]}ms
                            </span>
                          <% end %>
                        </div>

                        <%!-- Arguments --%>
                        <div>
                          <div class="apm-mono apm-upper" style="font-size:9.5px;color:var(--apm-text-dim);margin-bottom:6px;letter-spacing:0.1em">
                            Arguments
                          </div>
                          <JsonViewer.json_viewer data={@selected_call_data[:args] || %{}} />
                        </div>

                        <%!-- Result --%>
                        <%= if @selected_call_data[:result] do %>
                          <div>
                            <div class="apm-mono apm-upper" style="font-size:9.5px;color:var(--apm-text-dim);margin-bottom:6px;letter-spacing:0.1em">
                              Result
                            </div>
                            <JsonViewer.json_viewer data={@selected_call_data[:result]} />
                          </div>
                        <% end %>

                        <%!-- Audit cross-ref --%>
                        <%= if @audit_entries != [] do %>
                          <div>
                            <div class="apm-mono apm-upper" style="font-size:9.5px;color:var(--apm-text-dim);margin-bottom:6px;letter-spacing:0.1em">
                              Audit ({length(@audit_entries)})
                            </div>
                            <%= for entry <- @audit_entries do %>
                              <div class="apm-audit-entry" style="font-size:11.5px;padding:6px 0;border-bottom:1px solid var(--apm-border-subtle)">
                                <%!-- Redact-reveal micro-interaction: hover **** → blur→text via CSS --%>
                                <span class="apm-redact-reveal apm-mono">
                                  {Map.get(entry, :payload_preview, "****")}
                                </span>
                                <span style="color:var(--apm-text-dim);margin-left:8px">
                                  {Map.get(entry, :action, "recorded")}
                                </span>
                              </div>
                            <% end %>
                          </div>
                        <% end %>
                      </div>
                    <% else %>
                      <EmptyState.empty_state
                        icon="term"
                        title="Select a tool call"
                        body="Click a row in the timeline to inspect it."
                      />
                    <% end %>
                    <:footer>
                      <CoreButton.button
                        variant="ghost"
                        size="sm"
                        phx-click="navigate"
                        phx-value-id="inv-audit"
                      >
                        View in audit →
                      </CoreButton.button>
                    </:footer>
                  </Drawer.drawer>
                </:detail>

                <:empty_detail>
                  <div style="padding:32px">
                    <EmptyState.empty_state
                      icon="term"
                      title="Select a tool call"
                      body="Click a row in the tool-call timeline to open the inspector."
                    />
                  </div>
                </:empty_detail>
              </SplitView.split_view>
            <% end %>
          <% end %>
        </:body>
      </DetailPage.detail_page>

      <%!-- Circuit-breaker close confirm modal --%>
      <%= if @confirm_breaker do %>
        <Modal.modal
          id="confirm-close-breaker"
          title="Close circuit breaker?"
          kicker="Caution"
          on_close="cancel_close_breaker"
        >
          <p style="font-size:13px;color:var(--apm-text-muted)">
            Closing the circuit breaker will re-enable traffic for this session.
            Ensure the underlying issue is resolved before proceeding.
          </p>
          <:footer>
            <CoreButton.button variant="ghost" phx-click="cancel_close_breaker">Cancel</CoreButton.button>
            <CoreButton.button variant="danger" phx-click="close_breaker">Close breaker</CoreButton.button>
          </:footer>
        </Modal.modal>
      <% end %>
    </PageShell.page_shell>
    """
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp load_session(socket, session_id) do
    try do
      session = Sessions.get_with_context(session_id)

      tool_calls =
        if session do
          ToolCalls.for_session(session_id)
        else
          []
        end

      metrics = if session, do: Sessions.metrics(session), else: empty_metrics()

      socket
      |> assign(:session, session)
      |> assign(:tool_calls, tool_calls)
      |> assign(:metrics, metrics)
      |> assign(:loading, false)
      |> assign(:error, if(is_nil(session), do: "Session not found: #{session_id}", else: nil))
    rescue
      e ->
        require Logger
        Logger.error("[InvestigateSessionLive] load failed: #{inspect(e)}")
        socket |> assign(:loading, false) |> assign(:error, "Failed to load session.")
    end
  end

  defp load_tool_calls(socket, session_id) do
    try do
      tool_calls = ToolCalls.for_session(session_id)
      assign(socket, :tool_calls, tool_calls)
    rescue
      _ -> socket
    end
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  defp empty_metrics, do: %{duration_s: nil, tokens_in: 0, tokens_out: 0, tool_calls: 0, cost_usd: nil}

  defp find_call(_tool_calls, nil), do: nil
  defp find_call(tool_calls, id), do: Enum.find(tool_calls, &(&1[:id] == id))

  defp first_call_ms([]), do: System.system_time(:millisecond)
  defp first_call_ms([first | _]) do
    case first[:started_at] do
      %DateTime{} = dt -> DateTime.to_unix(dt, :millisecond)
      _ -> System.system_time(:millisecond) - 60_000
    end
  end

  defp timeline_window([]), do: 15 * 60 * 1_000

  defp timeline_window(calls) do
    start_ms = first_call_ms(calls)

    end_ms =
      calls
      |> Enum.map(fn tc ->
        case tc[:ended_at] do
          %DateTime{} = dt -> DateTime.to_unix(dt, :millisecond)
          _ -> System.system_time(:millisecond)
        end
      end)
      |> Enum.max(fn -> System.system_time(:millisecond) end)

    max(end_ms - start_ms + 5_000, 15 * 60 * 1_000)
  end

  defp format_duration(nil), do: "—"
  defp format_duration(s) when s < 60, do: "#{s}s"
  defp format_duration(s) when s < 3600, do: "#{div(s, 60)}m #{rem(s, 60)}s"
  defp format_duration(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  defp format_cost(nil), do: "—"
  defp format_cost(usd) when is_float(usd), do: "$#{:erlang.float_to_binary(usd, decimals: 4)}"
  defp format_cost(usd), do: "$#{usd}"

  defp truncate(s, n) when is_binary(s) and byte_size(s) > n, do: "#{String.slice(s, 0, n)}…"
  defp truncate(s, _), do: s || ""

  defp truncate_args(nil), do: ""
  defp truncate_args(args) when is_map(args) do
    args |> Jason.encode!() |> truncate(60)
  end
  defp truncate_args(args), do: truncate(inspect(args), 60)

  defp session_title(nil, id), do: id
  defp session_title(session, _), do: Map.get(session, :session_id, "Session")

  defp session_status_tone(nil), do: "neutral"
  defp session_status_tone(%{status: "active"}), do: "success"
  defp session_status_tone(%{status: "terminated"}), do: "neutral"
  defp session_status_tone(%{status: "error"}), do: "error"
  defp session_status_tone(_), do: "neutral"

  defp session_status_label(nil), do: "unknown"
  defp session_status_label(%{status: status}) when is_binary(status), do: status
  defp session_status_label(_), do: "unknown"

  defp status_tone(:completed), do: "success"
  defp status_tone(:error), do: "error"
  defp status_tone(:running), do: "info"
  defp status_tone(:pending), do: "warning"
  defp status_tone(_), do: "neutral"

  defp call_status_label(:completed), do: "completed"
  defp call_status_label(:error), do: "error"
  defp call_status_label(:running), do: "running"
  defp call_status_label(:pending), do: "pending"
  defp call_status_label(nil), do: "unknown"
  defp call_status_label(s), do: to_string(s)

  defp tc_latency_data(%{duration_ms: ms}) when is_integer(ms), do: [0, ms]
  defp tc_latency_data(_), do: [0, 1]

  defp nav_path("inv-sessions"), do: "/investigate/sessions"
  defp nav_path("inv-audit"), do: "/investigate/audit"
  defp nav_path("inv-toolcalls"), do: "/investigate/tool-calls"
  defp nav_path("pending"), do: "/decide/pending"
  defp nav_path("dashboard"), do: "/"
  defp nav_path("health"), do: "/operate/health"
  defp nav_path(id), do: "/#{id}"
end
