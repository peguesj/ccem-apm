defmodule ApmWeb.CoalesceLive do
  @moduledoc """
  LiveView for the Coalesce decision gate dashboard.

  Route: /coalesce and /coalesce?run=<run_id>

  Features:
  - Real-time run status via PubSub "apm:coalesce"
  - Decision gate panel — approve/reject/defer pending human gates
  - Diff viewer — side-by-side current vs. proposed skill content
  - Formation plan display — squadron topology
  - Run history list

  ## Known Coalesce Scopes

  | Scope atom | Module(s) affected |
  |:-----------|:-------------------|
  | `:security` | `Apm.Plugins.Security.SecurityGuidancePlugin` |
  | `:orchestration` | `Apm.Orchestration.OrchestrationManager`, `OrchestrationRunStore` |
  | `:memory` | `Apm.Plugins.Memory.MemoryPlugin`, `MemoryClientBridge`, `ObservationCache`, `ConversationMemoryCorrelator` |
  | `:skills` | `Apm.SkillTracker`, `SkillsRegistryStore` |
  | `:upm` | `Apm.UpmStore` |
  | `:formation` | `Apm.FormationSupervisor` and its children |
  """

  use ApmWeb, :live_view

  alias Apm.Coalesce.{CoalesceOrchestrator, DecisionGateStore}

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:coalesce")
    end

    run_id = params["run"]

    runs =
      try do
        CoalesceOrchestrator.list_runs()
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    active_run =
      if run_id,
        do:
          (try do
             CoalesceOrchestrator.get_run(run_id)
           rescue
             _ -> nil
           catch
             :exit, _ -> nil
           end),
        else: List.first(runs)

    pending_gates =
      try do
        DecisionGateStore.list_pending()
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    {:ok,
     socket
     |> assign(
       runs: runs,
       active_run: active_run,
       active_run_gates: _gates_for(active_run),
       pending_gates: pending_gates,
       selected_diff: nil,
       selected_gate: nil,
       flash_message: nil,
       page_title: "Coalesce — Skill Logic Engine"
     )
     |> ApmWeb.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  @impl true
  def handle_params(%{"run" => run_id}, _uri, socket) do
    run = CoalesceOrchestrator.get_run(run_id)

    {:noreply,
     assign(socket,
       active_run: run,
       active_run_gates: _gates_for(run)
     )}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_run", %{"run_id" => run_id}, socket) do
    run = CoalesceOrchestrator.get_run(run_id)

    {:noreply,
     assign(socket,
       active_run: run,
       active_run_gates: _gates_for(run),
       selected_diff: nil,
       selected_gate: nil
     )}
  end

  def handle_event("select_diff", %{"skill" => skill_name}, socket) do
    diff =
      case socket.assigns.active_run do
        nil -> nil
        run -> Enum.find(run.diffs, &(&1.skill_name == skill_name))
      end

    {:noreply, assign(socket, selected_diff: diff)}
  end

  def handle_event("close_diff", _params, socket) do
    {:noreply, assign(socket, selected_diff: nil)}
  end

  def handle_event("select_gate", %{"composite_id" => composite_id}, socket) do
    gate = DecisionGateStore.get(composite_id)
    {:noreply, assign(socket, selected_gate: gate)}
  end

  def handle_event("gate_approve", %{"composite_id" => composite_id}, socket) do
    case DecisionGateStore.approve(composite_id, %{approver: "dashboard"}) do
      :ok ->
        {:noreply, _reload_run(socket) |> put_flash(:info, "Gate approved")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot approve: #{inspect(reason)}")}
    end
  end

  def handle_event("gate_reject", %{"composite_id" => composite_id, "reason" => reason}, socket) do
    case DecisionGateStore.reject(composite_id, reason) do
      :ok ->
        {:noreply, _reload_run(socket) |> put_flash(:info, "Gate rejected")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot reject: #{inspect(reason)}")}
    end
  end

  def handle_event("gate_defer", %{"composite_id" => composite_id}, socket) do
    case DecisionGateStore.defer(composite_id, "deferred from dashboard") do
      :ok ->
        {:noreply, _reload_run(socket) |> put_flash(:info, "Gate deferred")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot defer: #{inspect(reason)}")}
    end
  end

  def handle_event("apply_run", %{"run_id" => run_id}, socket) do
    case CoalesceOrchestrator.apply_run(run_id) do
      {:ok, result} ->
        msg = "Applied #{result.applied} skill updates (#{result.skipped} skipped)"
        {:noreply, _reload_run(socket) |> put_flash(:info, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Apply failed: #{inspect(reason)}")}
    end
  end

  def handle_event("cancel_run", %{"run_id" => run_id}, socket) do
    CoalesceOrchestrator.cancel_run(run_id)

    {:noreply,
     assign(socket,
       runs: CoalesceOrchestrator.list_runs(),
       active_run: nil,
       active_run_gates: [],
       selected_diff: nil
     )
     |> put_flash(:info, "Run cancelled")}
  end

  # ── PubSub Handlers ───────────────────────────────────────────────────────

  @impl true
  def handle_info({:coalesce_run_started, run}, socket) do
    {:noreply,
     assign(socket,
       runs: CoalesceOrchestrator.list_runs(),
       active_run: run,
       active_run_gates: []
     )}
  end

  def handle_info({event, _payload}, socket)
      when event in [:coalesce_run_applied, :coalesce_run_cancelled, :coalesce_run_failed] do
    {:noreply, _reload_run(socket)}
  end

  def handle_info({:coalesce_gate_pending, %{run_id: run_id}}, socket) do
    gates = DecisionGateStore.list_for_run(run_id)
    pending = DecisionGateStore.list_pending()

    socket =
      if socket.assigns.active_run && socket.assigns.active_run.run_id == run_id do
        assign(socket, active_run_gates: gates)
      else
        socket
      end

    {:noreply, assign(socket, pending_gates: pending)}
  end

  def handle_info({event, gate}, socket)
      when event in [:coalesce_gate_approved, :coalesce_gate_rejected, :coalesce_gate_deferred] do
    run_id = gate.run_id
    gates = DecisionGateStore.list_for_run(run_id)
    pending = DecisionGateStore.list_pending()

    socket =
      if socket.assigns.active_run && socket.assigns.active_run.run_id == run_id do
        run = CoalesceOrchestrator.get_run(run_id)
        assign(socket, active_run: run, active_run_gates: gates)
      else
        socket
      end

    {:noreply, assign(socket, pending_gates: pending)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Render ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={false} inspector_open={@selected_diff != nil}>
      <:sidebar>
        <.sidebar_nav current_path="/coalesce" />
      </:sidebar>
      <:topbar>
        <.top_bar project_name="CCEM APM" />
      </:topbar>
      <:main>
        <div style="display: flex; height: 100%; overflow: hidden;">
          <!-- Left: Run List -->
          <div style="width: 260px; flex-shrink: 0; border-right: 1px solid var(--ccem-line); display: flex; flex-direction: column; overflow: hidden;">
            <div style="padding: 10px 14px; border-bottom: 1px solid var(--ccem-line); flex-shrink: 0;">
              <span style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-dim);">
                Run History
              </span>
            </div>
            <div style="flex: 1; overflow-y: auto;">
              <%= for run <- @runs do %>
                <button
                  phx-click="select_run"
                  phx-value-run_id={run.run_id}
                  style={"width: 100%; text-align: left; padding: 10px 14px; border-bottom: 1px solid var(--ccem-line-subtle, var(--ccem-line)); background: #{if @active_run && @active_run.run_id == run.run_id, do: "var(--ccem-bg-2)", else: "transparent"}; cursor: pointer;"}
                >
                  <div style="display: flex; align-items: center; justify-content: space-between; gap: 8px;">
                    <span style="font-family: var(--ccem-font-mono); font-size: 11px; color: var(--ccem-fg-dim); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                      {run.run_id}
                    </span>
                    <.badge tone={run_tone(run.status)}>{run.status}</.badge>
                  </div>
                  <div style="font-size: 11px; color: var(--ccem-fg-dim); margin-top: 2px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                    {run.scope}
                  </div>
                  <div style="font-size: 11px; color: var(--ccem-fg-dim); margin-top: 1px;">
                    {length(run.affected_skills)} skills · {length(run.diffs)} diffs
                  </div>
                </button>
              <% end %>
              <%= if Enum.empty?(@runs) do %>
                <div style="padding: 32px 16px; text-align: center; color: var(--ccem-fg-dim); font-size: 13px;">
                  No runs yet. Start one with <code>/coalesce</code>
                </div>
              <% end %>
            </div>
          </div>
          
    <!-- Center: Active Run -->
          <div style="flex: 1; display: flex; flex-direction: column; overflow: hidden;">
            <%= if @active_run do %>
              <!-- Run header -->
              <div style="padding: 16px; border-bottom: 1px solid var(--ccem-line); display: flex; align-items: flex-start; justify-content: space-between; flex-shrink: 0;">
                <div>
                  <div style="display: flex; align-items: center; gap: 10px; margin-bottom: 4px;">
                    <span style="font-family: var(--ccem-font-mono); font-size: 13px; font-weight: 600; color: var(--ccem-fg);">
                      {@active_run.run_id}
                    </span>
                    <%= if @active_run.dry_run do %>
                      <.badge tone="warning">DRY RUN</.badge>
                    <% end %>
                    <.badge tone={run_tone(@active_run.status)}>{@active_run.status}</.badge>
                  </div>
                  <div style="font-size: 12px; color: var(--ccem-fg-dim);">
                    Scope: <span style="color: var(--ccem-fg);">{@active_run.scope}</span>
                    &nbsp;·&nbsp;
                    Formation:
                    <span style="font-family: var(--ccem-font-mono); font-size: 11px; color: var(--ccem-accent);">
                      {@active_run.formation_id}
                    </span>
                  </div>
                </div>
                <div style="display: flex; gap: 8px;">
                  <%= if @active_run.status == :awaiting_gate do %>
                    <.btn
                      variant="primary"
                      size="sm"
                      phx-click="apply_run"
                      phx-value-run_id={@active_run.run_id}
                    >
                      Apply Diffs
                    </.btn>
                  <% end %>
                  <%= if @active_run.status in [:intelligence, :analysis, :generation, :validation, :awaiting_gate] do %>
                    <.btn
                      variant="ghost"
                      size="sm"
                      phx-click="cancel_run"
                      phx-value-run_id={@active_run.run_id}
                    >
                      Cancel
                    </.btn>
                  <% end %>
                </div>
              </div>
              
    <!-- Gate panel -->
              <%= if length(@active_run_gates) > 0 do %>
                <div style="padding: 14px 16px; border-bottom: 1px solid var(--ccem-line); background: var(--ccem-bg-0); flex-shrink: 0;">
                  <div style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-dim); margin-bottom: 10px;">
                    Decision Gates
                  </div>
                  <div style="display: flex; flex-wrap: wrap; gap: 8px;">
                    <%= for gate <- @active_run_gates do %>
                      <div style="display: flex; align-items: center; gap: 8px; padding: 8px 12px; border-radius: 6px; border: 1px solid var(--ccem-line);">
                        <.badge tone={gate_tone(gate.status)} dot={gate.status == :pending}>
                          {gate.gate_id}
                        </.badge>
                        <span style="font-size: 11px; color: var(--ccem-fg-dim);">{gate.type}</span>
                        <%= if gate.status == :pending and gate.type == :human do %>
                          <div style="display: flex; gap: 4px; margin-left: 4px;">
                            <.btn
                              variant="primary"
                              size="xs"
                              phx-click="gate_approve"
                              phx-value-composite_id={gate.composite_id}
                            >
                              Approve
                            </.btn>
                            <.btn
                              variant="destructive"
                              size="xs"
                              phx-click="gate_reject"
                              phx-value-composite_id={gate.composite_id}
                              phx-value-reason="rejected from dashboard"
                            >
                              Reject
                            </.btn>
                            <.btn
                              variant="ghost"
                              size="xs"
                              phx-click="gate_defer"
                              phx-value-composite_id={gate.composite_id}
                            >
                              Defer
                            </.btn>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
              
    <!-- Diffs list -->
              <div style="flex: 1; overflow-y: auto; padding: 16px;">
                <div style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-dim); margin-bottom: 12px;">
                  Proposed Skill Diffs ({length(@active_run.diffs)})
                </div>
                <%= if Enum.empty?(@active_run.diffs) do %>
                  <div style="text-align: center; padding: 40px 0; color: var(--ccem-fg-dim); font-size: 13px;">
                    <%= if @active_run.status in [:intelligence, :analysis] do %>
                      Generation in progress...
                    <% else %>
                      No diffs generated
                    <% end %>
                  </div>
                <% else %>
                  <.data_table id="diffs-table" rows={@active_run.diffs}>
                    <:col :let={diff} label="Impact">
                      <.badge tone={impact_tone(diff.impact)}>{diff.impact}</.badge>
                    </:col>
                    <:col :let={diff} label="Skill">
                      <span style="font-family: var(--ccem-font-mono); font-size: 12px;">
                        {diff.skill_name}
                      </span>
                    </:col>
                    <:col :let={diff} label="Additions">
                      {length(diff.additions)}
                    </:col>
                    <:col :let={diff} label="Confidence">
                      <span style={"font-family: var(--ccem-font-mono); font-size: 12px; #{confidence_style(diff.confidence)}"}>
                        {diff.confidence |> Kernel.*(100) |> Float.round(0) |> trunc()}%
                      </span>
                    </:col>
                    <:col :let={diff} label="Status">
                      <.badge tone={if diff.approved, do: "success", else: "warning"}>
                        {if diff.approved, do: "approved", else: "pending"}
                      </.badge>
                    </:col>
                    <:col :let={diff} label="">
                      <.btn
                        variant="ghost"
                        size="xs"
                        phx-click="select_diff"
                        phx-value-skill={diff.skill_name}
                      >
                        View Diff
                      </.btn>
                    </:col>
                  </.data_table>
                <% end %>
              </div>
            <% else %>
              <div style="flex: 1; display: flex; align-items: center; justify-content: center;">
                <div style="text-align: center; color: var(--ccem-fg-dim);">
                  <div style="font-size: 32px; margin-bottom: 16px;">⟐</div>
                  <div style="font-size: 15px; font-weight: 500; color: var(--ccem-fg);">
                    No active run
                  </div>
                  <div style="font-size: 12px; margin-top: 6px;">
                    Start one with <code style="color: var(--ccem-accent);">/coalesce</code>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </:main>
      <:inspector>
        <%= if @selected_diff do %>
          <div style="padding: 16px; height: 100%; overflow-y: auto;">
            <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
              <span style="font-family: var(--ccem-font-mono); font-size: 13px; font-weight: 600; color: var(--ccem-accent);">
                {@selected_diff.skill_name}
              </span>
              <.btn variant="ghost" size="xs" phx-click="close_diff">Close</.btn>
            </div>
            <div style="display: flex; flex-direction: column; gap: 12px;">
              <%= for addition <- @selected_diff.additions do %>
                <.card>
                  <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 8px;">
                    <.badge tone="success">{addition.type}</.badge>
                    <span style="font-size: 13px; font-weight: 600; color: var(--ccem-fg);">
                      {addition.section}
                    </span>
                  </div>
                  <pre style="font-family: var(--ccem-font-mono); font-size: 11px; color: var(--ccem-fg-dim); white-space: pre-wrap; overflow-x: auto;">{addition.content}</pre>
                </.card>
              <% end %>
            </div>
          </div>
        <% end %>
      </:inspector>
    </.page_layout>
    """
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp _gates_for(nil), do: []
  defp _gates_for(run), do: DecisionGateStore.list_for_run(run.run_id)

  defp _reload_run(socket) do
    run_id = socket.assigns.active_run && socket.assigns.active_run.run_id
    run = if run_id, do: CoalesceOrchestrator.get_run(run_id), else: nil

    assign(socket,
      runs: CoalesceOrchestrator.list_runs(),
      active_run: run,
      active_run_gates: _gates_for(run),
      pending_gates: DecisionGateStore.list_pending()
    )
  end

  defp run_tone(:intelligence), do: "info"
  defp run_tone(:analysis), do: "iris"
  defp run_tone(:generation), do: "accent"
  defp run_tone(:validation), do: "warning"
  defp run_tone(:awaiting_gate), do: "warning"
  defp run_tone(:applying), do: "success"
  defp run_tone(:complete), do: "success"
  defp run_tone(:cancelled), do: "neutral"
  defp run_tone(:failed), do: "error"
  defp run_tone(_), do: "neutral"

  defp gate_tone(:pending), do: "warning"
  defp gate_tone(:approved), do: "success"
  defp gate_tone(:rejected), do: "error"
  defp gate_tone(:deferred), do: "neutral"
  defp gate_tone(_), do: "neutral"

  defp impact_tone(:high), do: "error"
  defp impact_tone(:medium), do: "warning"
  defp impact_tone(:low), do: "success"
  defp impact_tone(_), do: "neutral"

  defp confidence_style(c) when c >= 0.85, do: "color: var(--ccem-ok, #22c55e);"
  defp confidence_style(c) when c >= 0.70, do: "color: var(--ccem-warn, #f59e0b);"
  defp confidence_style(_), do: "color: var(--ccem-err, #ef4444);"
end
