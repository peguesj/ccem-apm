defmodule ApmV5Web.GovernanceLive do
  @moduledoc """
  Governance Posture LiveView — /governance (CP-236 / US-468 / Plane 7b1d4261).

  Renders four live sections:

  1. **Header** — overall compliance score, last_updated, refresh button.
  2. **Controls** — table of all 13 ControlRegistry entries sorted gaps-first.
  3. **Compliance Posture** — per-framework progress bars for 7 frameworks.
  4. **Risk Scores** — top-10 sessions and formations from RiskScoreAggregator.
  5. **Active Circuit Breakers** — live list from IncidentResponseEngine with
     Force Close per row (calls POST /api/v2/governance/circuit-breakers/:id/close).

  PubSub:
  - `"auth:risks"`       → re-render risk widgets.
  - `"governance:circuits"` → re-render circuit breakers widget.
  - 30-second `:tick` timer → refresh compliance report.

  Spec: CP-236 / US-468 — auth-comp TRACK COMPLETE (10/10 v9.3.0).
  """

  use ApmV5Web, :live_view

  alias ApmV5.Governance.{ComplianceReportEngine, ControlRegistry, IncidentResponseEngine}
  alias ApmV5.Auth.RiskScoreAggregator

  @refresh_ms 30_000
  @top_n 10

  # ---------------------------------------------------------------------------
  # Mount
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "auth:risks")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "governance:circuits")
      Process.send_after(self(), :tick, @refresh_ms)
    end

    {:ok,
     socket
     |> assign(:page_title, "Governance Posture")
     |> assign(:sidebar_collapsed, false)
     |> assign(:inspector_open, false)
     |> load_compliance()
     |> load_controls()
     |> load_risk_scores()
     |> load_circuits()
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  # ---------------------------------------------------------------------------
  # handle_info
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @refresh_ms)
    {:noreply, socket |> load_compliance() |> load_risk_scores() |> load_circuits()}
  end

  # Re-render risk scores on any auth:risks broadcast
  def handle_info({:risk_aggregated, _key, _aggregate}, socket) do
    {:noreply, socket |> load_risk_scores()}
  end

  # Re-render circuits on circuit open/close
  def handle_info({:circuit_open, _session_id, _circuit}, socket) do
    {:noreply, load_circuits(socket)}
  end

  def handle_info({:circuit_close, _session_id}, socket) do
    {:noreply, load_circuits(socket)}
  end

  # Ignore unrecognised messages
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # handle_event
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("refresh", _params, socket) do
    report = safe_refresh_report()

    {:noreply,
     socket
     |> assign(:report, report)
     |> assign(:last_updated, report.generated_at)
     |> assign(:overall_score, report.overall_score)
     |> assign(:by_framework, report.by_framework)
     |> load_risk_scores()
     |> load_circuits()}
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_collapsed, !socket.assigns.sidebar_collapsed)}
  end

  @impl true
  def handle_event("toggle_inspector", _params, socket) do
    {:noreply, assign(socket, :inspector_open, !socket.assigns.inspector_open)}
  end

  @impl true
  def handle_event("close_circuit", %{"session_id" => session_id}, socket) do
    _result =
      try do
        IncidentResponseEngine.close_circuit(session_id)
      catch
        :exit, _ -> {:error, :unavailable}
      end

    {:noreply, load_circuits(socket)}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav current_path="/governance" />
      </:sidebar>

      <:topbar>
        <.top_bar project_name="CCEM APM" />
      </:topbar>

      <:main>
        <%!-- ── 1. Header ─────────────────────────────────────────────── --%>
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <h1 style="font-size:20px; font-weight:700; color:var(--ccem-fg); margin:0;">
              Governance Posture
            </h1>
            <.badge tone={score_tone(@overall_score)}>
              {score_label(@overall_score)} — {@overall_score}/100
            </.badge>
          </div>
          <div style="display:flex; align-items:center; gap:8px;">
            <span style="font-size:12px; color:var(--ccem-fg-muted);">
              Updated {format_dt(@last_updated)}
            </span>
            <.btn variant="ghost" size="sm" phx-click="refresh">Refresh</.btn>
            <.btn variant="ghost" size="sm" phx-click="toggle_sidebar">
              {if @sidebar_collapsed, do: "Expand", else: "Collapse"}
            </.btn>
          </div>
        </div>

        <%!-- Overall stat tiles row --%>
        <div style="display:grid; grid-template-columns:repeat(4,1fr); gap:12px; margin-bottom:24px;">
          <.card>
            <.stat_tile label="Overall Score" value={"#{@overall_score}/100"} />
          </.card>
          <.card>
            <.stat_tile label="Controls Satisfied" value={to_string(@report.controls_by_status.satisfied)} />
          </.card>
          <.card>
            <.stat_tile label="Partial" value={to_string(@report.controls_by_status.partial)} />
          </.card>
          <.card>
            <.stat_tile label="Gaps" value={to_string(@report.controls_by_status.gap + @report.controls_by_status.absent)} />
          </.card>
        </div>

        <%!-- ── 2. Controls Section ─────────────────────────────────────── --%>
        <.card style="margin-bottom:24px;" padded={false}>
          <div style="padding:12px 16px; border-bottom:1px solid var(--ccem-line-subtle);">
            <p style="font-size:12px; font-weight:600; color:var(--ccem-fg-dim); text-transform:uppercase; letter-spacing:0.06em; margin:0;">
              Controls ({length(@controls)} registered)
            </p>
          </div>
          <.data_table id="controls-table" rows={@controls}>
            <:col :let={ctrl} label="ID">
              <span style="font-family:var(--ccem-font-mono); font-size:11px; color:var(--ccem-fg-muted);">
                {ctrl.id}
              </span>
            </:col>
            <:col :let={ctrl} label="Name">
              <span style="font-size:13px; font-weight:500; color:var(--ccem-fg);">{ctrl.name}</span>
            </:col>
            <:col :let={ctrl} label="Status">
              <.badge tone={status_tone(ctrl.status)}>
                {String.upcase(to_string(ctrl.status))}
              </.badge>
            </:col>
            <:col :let={ctrl} label="Frameworks">
              <div style="display:flex; flex-wrap:wrap; gap:4px;">
                <%= for fw <- ctrl_frameworks(ctrl) do %>
                  <.badge tone="neutral">{fw}</.badge>
                <% end %>
              </div>
            </:col>
          </.data_table>
        </.card>

        <%!-- ── 3. Compliance Posture Widget ──────────────────────────────── --%>
        <.card style="margin-bottom:24px;">
          <p style="font-size:12px; font-weight:600; color:var(--ccem-fg-dim); text-transform:uppercase; letter-spacing:0.06em; margin:0 0 16px;">
            Compliance Posture by Framework
          </p>
          <div style="display:flex; flex-direction:column; gap:16px;">
            <%= for fw <- [:nist_ai_rmf, :soc2, :iso_27001, :nist_csf, :eu_ai_act, :pci_dss, :cis] do %>
              <% fw_data = Map.get(@by_framework, fw, %{score: 0, controls: []}) %>
              <% satisfied = Enum.count(fw_data.controls, &(&1.status == :satisfied)) %>
              <% partial    = Enum.count(fw_data.controls, &(&1.status == :partial)) %>
              <% gap        = Enum.count(fw_data.controls, &(&1.status in [:gap, :absent])) %>
              <div>
                <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:6px;">
                  <span style="font-size:13px; font-weight:500; color:var(--ccem-fg);">
                    {format_framework(fw)}
                  </span>
                  <div style="display:flex; align-items:center; gap:8px;">
                    <span style="font-size:13px; font-weight:600; color:var(--ccem-fg); font-variant-numeric:tabular-nums;">
                      {fw_data.score}/100
                    </span>
                    <.badge tone="success">{satisfied}</.badge>
                    <%= if partial > 0 do %>
                      <.badge tone="warning">{partial}</.badge>
                    <% end %>
                    <%= if gap > 0 do %>
                      <.badge tone="error">{gap}</.badge>
                    <% end %>
                  </div>
                </div>
                <div style="height:6px; background:var(--ccem-bg-2); border-radius:3px; overflow:hidden;">
                  <div
                    style={"height:100%; width:#{fw_data.score}%; background:#{score_bar_color(fw_data.score)}; border-radius:3px; transition:width 0.4s ease;"}
                  >
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        </.card>

        <%!-- ── 4. Risk Scores Widget ───────────────────────────────────────── --%>
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-bottom:24px;">
          <.card padded={false}>
            <div style="padding:12px 16px; border-bottom:1px solid var(--ccem-line-subtle);">
              <p style="font-size:12px; font-weight:600; color:var(--ccem-fg-dim); text-transform:uppercase; letter-spacing:0.06em; margin:0;">
                Top Sessions by Risk
              </p>
            </div>
            <%= if @top_sessions == [] do %>
              <div style="padding:20px; text-align:center; color:var(--ccem-fg-muted); font-size:13px;">
                No session risk data yet
              </div>
            <% else %>
              <.data_table id="top-sessions-table" rows={@top_sessions}>
                <:col :let={{sid, _agg}} label="Session">
                  <span style="font-family:var(--ccem-font-mono); font-size:11px; color:var(--ccem-fg-muted);">
                    {truncate_id(sid)}
                  </span>
                </:col>
                <:col :let={{_sid, agg}} label="Score">
                  <span style="font-size:13px; font-weight:600; font-variant-numeric:tabular-nums;">
                    {Float.round(agg.score, 2)}
                  </span>
                </:col>
                <:col :let={{_sid, agg}} label="Level">
                  <.badge tone={risk_tone(agg.level)}>{agg.level}</.badge>
                </:col>
                <:col :let={{_sid, agg}} label="Calls">
                  <span style="font-size:12px; color:var(--ccem-fg-muted);">{agg.tool_call_count}</span>
                </:col>
              </.data_table>
            <% end %>
          </.card>

          <.card padded={false}>
            <div style="padding:12px 16px; border-bottom:1px solid var(--ccem-line-subtle);">
              <p style="font-size:12px; font-weight:600; color:var(--ccem-fg-dim); text-transform:uppercase; letter-spacing:0.06em; margin:0;">
                Top Formations by Risk
              </p>
            </div>
            <%= if @top_formations == [] do %>
              <div style="padding:20px; text-align:center; color:var(--ccem-fg-muted); font-size:13px;">
                No formation risk data yet
              </div>
            <% else %>
              <.data_table id="top-formations-table" rows={@top_formations}>
                <:col :let={{fid, _agg}} label="Formation">
                  <span style="font-family:var(--ccem-font-mono); font-size:11px; color:var(--ccem-fg-muted);">
                    {truncate_id(fid)}
                  </span>
                </:col>
                <:col :let={{_fid, agg}} label="Score">
                  <span style="font-size:13px; font-weight:600; font-variant-numeric:tabular-nums;">
                    {Float.round(agg.score, 2)}
                  </span>
                </:col>
                <:col :let={{_fid, agg}} label="Level">
                  <.badge tone={risk_tone(agg.level)}>{agg.level}</.badge>
                </:col>
                <:col :let={{_fid, agg}} label="Calls">
                  <span style="font-size:12px; color:var(--ccem-fg-muted);">{agg.tool_call_count}</span>
                </:col>
              </.data_table>
            <% end %>
          </.card>
        </div>

        <%!-- ── 5. Active Circuit Breakers Widget ────────────────────────────── --%>
        <.card padded={false}>
          <div style="padding:12px 16px; border-bottom:1px solid var(--ccem-line-subtle); display:flex; align-items:center; justify-content:space-between;">
            <p style="font-size:12px; font-weight:600; color:var(--ccem-fg-dim); text-transform:uppercase; letter-spacing:0.06em; margin:0;">
              Active Circuit Breakers
            </p>
            <%= if length(@circuits) > 0 do %>
              <.badge tone="error" dot>{length(@circuits)} open</.badge>
            <% else %>
              <.badge tone="success">None</.badge>
            <% end %>
          </div>
          <%= if @circuits == [] do %>
            <div style="padding:24px; text-align:center; color:var(--ccem-fg-muted); font-size:13px;">
              No active circuit breakers — all sessions operating normally
            </div>
          <% else %>
            <.data_table id="circuits-table" rows={@circuits}>
              <:col :let={cb} label="Session">
                <span style="font-family:var(--ccem-font-mono); font-size:11px; color:var(--ccem-fg-muted);">
                  {truncate_id(cb.session_id)}
                </span>
              </:col>
              <:col :let={cb} label="Opened">
                <span style="font-size:12px; color:var(--ccem-fg-muted);">{cb.opened_at}</span>
              </:col>
              <:col :let={cb} label="TTL Remaining">
                <span style="font-size:12px; font-variant-numeric:tabular-nums; color:var(--ccem-fg);">
                  {ttl_remaining_seconds(cb)}s
                </span>
              </:col>
              <:col :let={cb} label="Reason">
                <.badge tone="warning">{cb.reason}</.badge>
              </:col>
              <:col :let={cb} label="">
                <.btn
                  variant="destructive"
                  size="xs"
                  phx-click="close_circuit"
                  phx-value-session_id={cb.session_id}
                >
                  Force Close
                </.btn>
              </:col>
            </.data_table>
          <% end %>
        </.card>
      </:main>

      <:inspector>
        <.inspector_panel open={@inspector_open} mode="filters" on_close="toggle_inspector">
          <:filters>
            <div style="padding:8px 0;">
              <p style="font-size:12px; font-weight:600; color:var(--ccem-fg-dim); text-transform:uppercase; letter-spacing:0.06em; margin:0 0 12px;">
                Governance Info
              </p>
              <p style="font-size:12px; color:var(--ccem-fg-muted); margin:0 0 8px;">
                Report generated every 5 minutes. Use Refresh to force update.
              </p>
              <p style="font-size:12px; color:var(--ccem-fg-muted); margin:0 0 8px;">
                Circuit breakers auto-close after 15 minutes. Force Close ends the
                denial rule immediately.
              </p>
              <div style="margin-top:12px; display:flex; flex-direction:column; gap:6px;">
                <div style="display:flex; align-items:center; justify-content:space-between;">
                  <span style="font-size:12px; color:var(--ccem-fg);">KRI Denial Rate</span>
                  <span style="font-size:12px; font-family:var(--ccem-font-mono); color:var(--ccem-fg-muted);">
                    {format_kri(@report.kri_snapshot.denial_rate)}
                  </span>
                </div>
                <div style="display:flex; align-items:center; justify-content:space-between;">
                  <span style="font-size:12px; color:var(--ccem-fg);">KRI Escalation Rate</span>
                  <span style="font-size:12px; font-family:var(--ccem-font-mono); color:var(--ccem-fg-muted);">
                    {format_kri(@report.kri_snapshot.escalation_rate)}
                  </span>
                </div>
                <div style="display:flex; align-items:center; justify-content:space-between;">
                  <span style="font-size:12px; color:var(--ccem-fg);">KRI Critical Cmd Rate</span>
                  <span style="font-size:12px; font-family:var(--ccem-font-mono); color:var(--ccem-fg-muted);">
                    {format_kri(@report.kri_snapshot.critical_command_rate)}
                  </span>
                </div>
                <div style="display:flex; align-items:center; justify-content:space-between;">
                  <span style="font-size:12px; color:var(--ccem-fg);">Risk Score P95</span>
                  <span style="font-size:12px; font-family:var(--ccem-font-mono); color:var(--ccem-fg-muted);">
                    {format_kri(@report.kri_snapshot.risk_score_p95)}
                  </span>
                </div>
              </div>
            </div>
          </:filters>
          <:selection>
            <p style="font-size:13px; color:var(--ccem-fg-muted); padding:8px 0;">
              Governance posture overview. Select a circuit or control row for details.
            </p>
          </:selection>
        </.inspector_panel>
      </:inspector>
    </.page_layout>
    """
  end

  # ---------------------------------------------------------------------------
  # Private — data loaders
  # ---------------------------------------------------------------------------

  @spec load_compliance(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_compliance(socket) do
    report = safe_generate_report()

    socket
    |> assign(:report, report)
    |> assign(:overall_score, report.overall_score)
    |> assign(:last_updated, report.generated_at)
    |> assign(:by_framework, report.by_framework)
  end

  @spec load_controls(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_controls(socket) do
    controls =
      ControlRegistry.list_controls()
      |> Enum.map(fn {id, ctrl} ->
        %{id: id, name: ctrl.name, status: ctrl.status, raw: ctrl}
      end)
      |> Enum.sort_by(fn %{status: s} -> status_sort_key(s) end)

    assign(socket, :controls, controls)
  end

  @spec load_risk_scores(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_risk_scores(socket) do
    top_sessions =
      try do
        RiskScoreAggregator.top_sessions(@top_n)
      catch
        :exit, _ -> []
      end

    top_formations =
      try do
        RiskScoreAggregator.top_formations(@top_n)
      catch
        :exit, _ -> []
      end

    socket
    |> assign(:top_sessions, top_sessions)
    |> assign(:top_formations, top_formations)
  end

  @spec load_circuits(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_circuits(socket) do
    circuits =
      try do
        IncidentResponseEngine.list_active_circuits()
      catch
        :exit, _ -> []
      end

    assign(socket, :circuits, circuits)
  end

  # ---------------------------------------------------------------------------
  # Private — safe wrappers
  # ---------------------------------------------------------------------------

  defp safe_generate_report do
    try do
      ComplianceReportEngine.generate()
    rescue
      _ -> empty_report()
    catch
      :exit, _ -> empty_report()
    end
  end

  defp safe_refresh_report do
    try do
      ComplianceReportEngine.refresh()
    rescue
      _ -> empty_report()
    catch
      :exit, _ -> empty_report()
    end
  end

  defp empty_report do
    %{
      generated_at: DateTime.utc_now(),
      overall_score: 0,
      controls_by_status: %{satisfied: 0, partial: 0, gap: 0, absent: 0},
      by_framework: %{},
      controls: [],
      kri_snapshot: %{
        denial_rate: nil,
        escalation_rate: nil,
        critical_command_rate: nil,
        trust_degradation_events: nil,
        policy_rule_changes: nil,
        risk_score_p95: nil
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Private — template helpers
  # ---------------------------------------------------------------------------

  defp status_sort_key(:gap), do: 0
  defp status_sort_key(:absent), do: 1
  defp status_sort_key(:partial), do: 2
  defp status_sort_key(:satisfied), do: 3
  defp status_sort_key(_), do: 4

  defp status_tone(:satisfied), do: "success"
  defp status_tone(:partial), do: "warning"
  defp status_tone(:gap), do: "error"
  defp status_tone(:absent), do: "error"
  defp status_tone(_), do: "neutral"

  defp score_tone(s) when s >= 80, do: "success"
  defp score_tone(s) when s >= 50, do: "warning"
  defp score_tone(_), do: "error"

  defp score_label(s) when s >= 80, do: "Good"
  defp score_label(s) when s >= 50, do: "Moderate"
  defp score_label(_), do: "At Risk"

  defp score_bar_color(s) when s >= 80, do: "var(--ccem-success, #3dd68c)"
  defp score_bar_color(s) when s >= 50, do: "var(--ccem-warn, #f5a623)"
  defp score_bar_color(_), do: "var(--ccem-err, #e5534b)"

  defp risk_tone(:none), do: "success"
  defp risk_tone(:low), do: "info"
  defp risk_tone(:medium), do: "warning"
  defp risk_tone(:high), do: "error"
  defp risk_tone(:critical), do: "error"
  defp risk_tone(_), do: "neutral"

  defp format_framework(:nist_ai_rmf), do: "NIST AI RMF"
  defp format_framework(:soc2), do: "SOC 2"
  defp format_framework(:iso_27001), do: "ISO 27001"
  defp format_framework(:nist_csf), do: "NIST CSF"
  defp format_framework(:eu_ai_act), do: "EU AI Act"
  defp format_framework(:pci_dss), do: "PCI DSS"
  defp format_framework(:cis), do: "CIS"
  defp format_framework(fw), do: to_string(fw)

  # Extracts the list of framework keys a control references.
  defp ctrl_frameworks(%{raw: ctrl}) do
    [:nist_ai_rmf, :soc2, :iso_27001, :nist_csf, :pci_dss, :eu_ai_act, :cis]
    |> Enum.filter(&Map.has_key?(ctrl, &1))
    |> Enum.map(&format_framework/1)
  end

  defp ctrl_frameworks(_), do: []

  defp truncate_id(id) when is_binary(id) and byte_size(id) > 16 do
    String.slice(id, 0, 8) <> "..."
  end

  defp truncate_id(id), do: to_string(id)

  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_dt(_), do: "—"

  defp format_kri(nil), do: "N/A"
  defp format_kri(v) when is_float(v), do: Float.round(v, 4) |> to_string()
  defp format_kri(v), do: to_string(v)

  # Computes approximate TTL remaining from opened_at + ttl_seconds
  defp ttl_remaining_seconds(%{opened_at: opened_at_str, ttl_seconds: ttl}) do
    case DateTime.from_iso8601(to_string(opened_at_str)) do
      {:ok, opened_at, _} ->
        elapsed = DateTime.diff(DateTime.utc_now(), opened_at, :second)
        max(ttl - elapsed, 0)

      _ ->
        ttl
    end
  end

  defp ttl_remaining_seconds(%{ttl_seconds: ttl}), do: ttl
  defp ttl_remaining_seconds(_), do: 0
end
