defmodule ApmV5Web.WiringMonitorLive do
  @moduledoc """
  Phase 0.4 — Wiring Monitor LiveView.

  Mounts at `/health/wiring` and continuously verifies the integrity of the
  Phoenix wiring between routes, controllers/LiveViews, phx-hook registrations,
  and PubSub topic coverage.

  ## Design

  The LiveView is intentionally a **sibling** to the existing `/health`
  (HealthCheckLive) rather than a tab inside it, to avoid touching that
  LiveView's render function (additive-only constraint for Phase 0.x).

  TODO (Phase 3 — Operate section migration): move this route to
  `/operate/health` as a "Wiring" tab once the /operate layout lands.

  ## Refresh strategy

  - On mount: `run_checks/0` immediately.
  - If connected: `Process.send_after(self(), :refresh, 30_000)` to re-scan
    every 30 s.
  - Subscribes to `"apm:wiring"` PubSub topic so an external trigger (e.g. a
    future GenServer from Phase 1) can push fresh results without waiting for
    the next poll cycle.
  """

  use ApmV5Web, :live_view

  require Logger

  alias ApmV5.WiringMonitor
  alias ApmV5.WiringMonitor.Finding

  @refresh_ms 30_000
  @pubsub_topic "apm:wiring"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic)
      schedule_refresh()
    end

    {:ok,
     socket
     |> assign(
       page_title:   "Wiring Monitor",
       sidebar_collapsed: false,
       inspector_open:    false,
       active_check:      nil
     )
     |> assign_checks()
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign_checks(socket)}
  end

  def handle_info({:wiring, _summary}, socket) do
    # A GenServer (future Phase 1 work) may push a summary; re-run our own scan
    # to get the full findings list.
    {:noreply, assign_checks(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_check", %{"check" => check}, socket) do
    check_atom = String.to_existing_atom(check)
    current    = socket.assigns.active_check

    active =
      if current == check_atom do
        nil
      else
        check_atom
      end

    {:noreply, assign(socket, active_check: active)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, assign_checks(socket)}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar><.sidebar_nav current_path="/health/wiring" /></:sidebar>
      <:topbar><.top_bar project_name="CCEM APM" /></:topbar>
      <:main>
        <%!-- Page header --%>
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
          <div style="display: flex; align-items: center; gap: 10px;">
            <h1 style="margin: 0; font-size: 16px; font-weight: 600; color: var(--ccem-fg);">
              Wiring Monitor
            </h1>
            <.badge tone={overall_tone(@summary)}>
              <%= overall_label(@summary) %>
            </.badge>
          </div>
          <div style="display: flex; align-items: center; gap: 8px;">
            <span style="font-size: var(--ccem-t-xs, 11px); color: var(--ccem-fg-dim);">
              Last scanned: <%= format_time(@scanned_at) %>
            </span>
            <.btn variant="ghost" size="xs" phx-click="refresh">Refresh</.btn>
          </div>
        </div>

        <%!-- Error banner if any errors found --%>
        <div
          :if={@summary.error > 0}
          style="
            background: var(--ccem-error-subtle, #2d1b1b);
            border: 1px solid var(--ccem-error, #ef4444);
            border-radius: 6px;
            padding: 10px 14px;
            margin-bottom: 16px;
            font-size: var(--ccem-t-sm, 13px);
            color: var(--ccem-error, #ef4444);
          "
        >
          <%= @summary.error %> wiring <%= pluralize("error", "errors", @summary.error) %> detected.
          Broken wires will prevent correct real-time behaviour under live sessions.
        </div>

        <%!-- Summary strip: one stat per check --%>
        <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin-bottom: 20px;">
          <%= for {check_id, label, desc} <- check_meta() do %>
            <% check_findings = findings_for(@findings, check_id) %>
            <% errors   = Enum.count(check_findings, &(&1.severity == :error)) %>
            <% warnings = Enum.count(check_findings, &(&1.severity == :warning)) %>
            <% tone     = check_tone(errors, warnings) %>
            <.card padded={true}
              style={"cursor: pointer; border-left: 3px solid var(--ccem-#{tone_border_var(tone)}); #{if @active_check == check_id, do: "box-shadow: 0 0 0 2px var(--ccem-primary, #6366f1);", else: ""}"}
              phx-click="toggle_check"
              phx-value-check={to_string(check_id)}>
              <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 4px;">
                <span style="font-size: var(--ccem-t-xs, 11px); font-weight: 600; color: var(--ccem-fg-dim); text-transform: uppercase; letter-spacing: 0.05em;">
                  <%= to_string(check_id) %>
                </span>
                <.badge tone={tone}>
                  <%= cond do
                    errors > 0   -> "#{errors} err"
                    warnings > 0 -> "#{warnings} warn"
                    true         -> "ok"
                  end %>
                </.badge>
              </div>
              <div style="font-size: var(--ccem-t-sm, 13px); font-weight: 600; color: var(--ccem-fg); margin-bottom: 2px;">
                <%= label %>
              </div>
              <div style="font-size: var(--ccem-t-xs, 11px); color: var(--ccem-fg-dim);">
                <%= desc %>
              </div>
            </.card>
          <% end %>
        </div>

        <%!-- Per-check findings tables (expanded when a check card is clicked) --%>
        <%= for {check_id, label, _desc} <- check_meta() do %>
          <% check_findings = findings_for(@findings, check_id) %>
          <div :if={@active_check == check_id} style="margin-bottom: 20px;">
            <h2 style="font-size: 14px; font-weight: 600; color: var(--ccem-fg); margin: 0 0 10px;">
              <%= to_string(check_id) %> — <%= label %>
            </h2>

            <div :if={check_findings == []}
                 style="text-align: center; padding: 24px; color: var(--ccem-fg-dim); font-size: var(--ccem-t-sm, 13px); border: 1px dashed var(--ccem-border, #333); border-radius: 6px;">
              All wiring connections healthy
            </div>

            <.card :if={check_findings != []} padded={false}>
              <.data_table id={"wiring-#{to_string(check_id)}-table"} rows={check_findings}>
                <:col :let={row} label="Severity">
                  <.badge tone={Finding.tone(row)}>
                    <%= to_string(row.severity) %>
                  </.badge>
                </:col>
                <:col :let={row} label="Subject">
                  <span style="font-family: monospace; font-size: var(--ccem-t-xs, 11px); color: var(--ccem-fg);">
                    <%= row.subject %>
                  </span>
                </:col>
                <:col :let={row} label="Detail">
                  <span style="font-size: var(--ccem-t-sm, 13px); color: var(--ccem-fg-dim);">
                    <%= row.detail %>
                  </span>
                </:col>
              </.data_table>
            </.card>
          </div>
        <% end %>

        <%!-- Show all findings table (non-success) when no specific check selected --%>
        <div :if={is_nil(@active_check)}>
          <% problem_findings = Enum.reject(@findings, &(&1.severity == :success)) %>
          <div :if={problem_findings == []}
               style="text-align: center; padding: 32px; color: var(--ccem-fg-dim); font-size: var(--ccem-t-sm, 13px); border: 1px dashed var(--ccem-border, #333); border-radius: 6px;">
            All wires connected — no issues found
          </div>
          <.card :if={problem_findings != []} padded={false}>
            <div style="padding: 10px 14px; border-bottom: 1px solid var(--ccem-border, #333); font-size: var(--ccem-t-xs, 11px); font-weight: 600; color: var(--ccem-fg-dim);">
              ISSUES (<%= length(problem_findings) %>) — click a check card above to see full results
            </div>
            <.data_table id="wiring-issues-table" rows={problem_findings}>
              <:col :let={row} label="Check">
                <span style="font-family: monospace; font-size: var(--ccem-t-xs, 11px); font-weight: 600; color: var(--ccem-fg);">
                  <%= to_string(row.check) %>
                </span>
              </:col>
              <:col :let={row} label="Severity">
                <.badge tone={Finding.tone(row)}>
                  <%= to_string(row.severity) %>
                </.badge>
              </:col>
              <:col :let={row} label="Subject">
                <span style="font-family: monospace; font-size: var(--ccem-t-xs, 11px); color: var(--ccem-fg);">
                  <%= row.subject %>
                </span>
              </:col>
              <:col :let={row} label="Detail">
                <span style="font-size: var(--ccem-t-sm, 13px); color: var(--ccem-fg-dim);">
                  <%= row.detail %>
                </span>
              </:col>
            </.data_table>
          </.card>
        </div>
      </:main>
    </.page_layout>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp assign_checks(socket) do
    findings   = WiringMonitor.run_all()
    summary    = WiringMonitor.summary(findings)
    scanned_at = DateTime.utc_now()

    assign(socket, findings: findings, summary: summary, scanned_at: scanned_at)
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_ms)
  end

  defp findings_for(findings, check_id) do
    Enum.filter(findings, &(&1.check == check_id))
  end

  defp check_meta do
    [
      {:W1, "Route Resolution",   "every route → module exists & exports action"},
      {:W2, "LiveView Coverage",  "every *Live module referenced by ≥1 route"},
      {:W3, "Hook Registration",  "every phx-hook registered in app.js Hooks"},
      {:W4, "PubSub Coverage",    "every subscribed topic has a publisher"}
    ]
  end

  defp check_tone(errors, _warnings) when errors > 0, do: "error"
  defp check_tone(_errors, warnings) when warnings > 0, do: "warning"
  defp check_tone(_, _), do: "success"

  defp tone_border_var("error"),   do: "error"
  defp tone_border_var("warning"), do: "warning"
  defp tone_border_var("success"), do: "success"
  defp tone_border_var(_),         do: "border"

  defp overall_tone(%{error: e}) when e > 0, do: "error"
  defp overall_tone(%{warning: w}) when w > 0, do: "warning"
  defp overall_tone(_), do: "success"

  defp overall_label(%{error: 0, warning: 0}), do: "all wires connected"
  defp overall_label(%{error: 0, warning: w}), do: "#{w} warning#{if w == 1, do: "", else: "s"}"
  defp overall_label(%{error: e}), do: "#{e} error#{if e == 1, do: "", else: "s"}"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S UTC")
  end

  defp format_time(_), do: "—"

  # Allow plural labels without conflicting with imported Gettext.Macros.ngettext/3
  defp pluralize(singular, _plural, 1), do: singular
  defp pluralize(_singular, plural, _n), do: plural
end
