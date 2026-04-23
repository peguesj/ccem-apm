defmodule ApmV5Web.CoalesceLive do
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
  | `:security` | `ApmV5.Plugins.Security.SecurityGuidancePlugin` |
  | `:orchestration` | `ApmV5.Orchestration.OrchestrationManager`, `OrchestrationRunStore` |
  | `:memory` | `ApmV5.Plugins.Memory.MemoryPlugin`, `MemoryClientBridge`, `ObservationCache`, `ConversationMemoryCorrelator` |
  | `:skills` | `ApmV5.SkillTracker`, `SkillsRegistryStore` |
  | `:upm` | `ApmV5.UpmStore` |
  | `:formation` | `ApmV5.FormationSupervisor` and its children |
  """

  use ApmV5Web, :live_view

  alias ApmV5.Coalesce.{CoalesceOrchestrator, DecisionGateStore}

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:coalesce")
    end

    run_id = params["run"]

    runs = CoalesceOrchestrator.list_runs()
    active_run = if run_id, do: CoalesceOrchestrator.get_run(run_id), else: List.first(runs)
    pending_gates = DecisionGateStore.list_pending()

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
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  @impl true
  def handle_params(%{"run" => run_id}, _uri, socket) do
    run = CoalesceOrchestrator.get_run(run_id)
    {:noreply, assign(socket,
      active_run: run,
      active_run_gates: _gates_for(run)
    )}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_run", %{"run_id" => run_id}, socket) do
    run = CoalesceOrchestrator.get_run(run_id)
    {:noreply, assign(socket,
      active_run: run,
      active_run_gates: _gates_for(run),
      selected_diff: nil,
      selected_gate: nil
    )}
  end

  def handle_event("select_diff", %{"skill" => skill_name}, socket) do
    diff = case socket.assigns.active_run do
      nil -> nil
      run -> Enum.find(run.diffs, & &1.skill_name == skill_name)
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

    {:noreply, assign(socket,
      runs: CoalesceOrchestrator.list_runs(),
      active_run: nil,
      active_run_gates: [],
      selected_diff: nil
    ) |> put_flash(:info, "Run cancelled")}
  end

  # ── PubSub Handlers ───────────────────────────────────────────────────────

  @impl true
  def handle_info({:coalesce_run_started, run}, socket) do
    {:noreply, assign(socket,
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

    socket = if socket.assigns.active_run && socket.assigns.active_run.run_id == run_id do
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

    socket = if socket.assigns.active_run && socket.assigns.active_run.run_id == run_id do
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
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <.sidebar_nav current_path="/coalesce" />

      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0 relative z-10">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Coalesce</h2>
            <div class="badge badge-sm badge-ghost"><%= length(@runs) %> runs</div>
            <div class="badge badge-sm badge-warning badge-outline"><%= length(@pending_gates) %> pending gates</div>
          </div>
        </header>

        <div class="flex flex-1 overflow-hidden">
          <!-- Left: Run List -->
          <div class="w-72 border-r border-base-300 flex flex-col bg-base-200">
            <div class="p-3 border-b border-base-300">
              <h3 class="text-xs font-semibold text-base-content/60 uppercase tracking-wider">Run History</h3>
            </div>

            <div class="flex-1 overflow-y-auto">
              <%= for run <- @runs do %>
                <button
                  phx-click="select_run"
                  phx-value-run_id={run.run_id}
                  class={"w-full text-left px-4 py-3 border-b border-base-300/50 hover:bg-base-300/50 transition-colors #{if @active_run && @active_run.run_id == run.run_id, do: "bg-base-300 border-l-2 border-l-primary", else: ""}"}
                >
                  <div class="flex items-center justify-between">
                    <span class="text-xs font-mono text-base-content/60 truncate"><%= run.run_id %></span>
                    <span class={"text-xs px-1.5 py-0.5 rounded #{_status_color(run.status)}"}>
                      <%= run.status %>
                    </span>
                  </div>
                  <div class="text-xs text-base-content/40 mt-1 truncate"><%= run.scope %></div>
                  <div class="text-xs text-base-content/30 mt-0.5">
                    <%= length(run.affected_skills) %> skills · <%= length(run.diffs) %> diffs
                  </div>
                </button>
              <% end %>

              <%= if Enum.empty?(@runs) do %>
                <div class="px-4 py-8 text-center text-base-content/30 text-sm">
                  No runs yet.<br/>
                  Start one with <code class="text-primary">/coalesce</code>
                </div>
              <% end %>
            </div>
          </div>

      <!-- Center: Active Run -->
      <div class="flex-1 flex flex-col overflow-hidden">
        <%= if @active_run do %>
          <!-- Run Header -->
          <div class="p-4 border-b border-zinc-800 flex items-center justify-between">
            <div>
              <div class="flex items-center gap-3">
                <h1 class="text-base font-semibold">
                  <%= @active_run.run_id %>
                  <%= if @active_run.dry_run do %>
                    <span class="text-xs text-amber-400 ml-2">[DRY RUN]</span>
                  <% end %>
                </h1>
                <span class={"text-sm px-2 py-0.5 rounded #{_status_color(@active_run.status)}"}>
                  <%= @active_run.status %>
                </span>
              </div>
              <div class="text-sm text-zinc-400 mt-1">
                Scope: <span class="text-zinc-300"><%= @active_run.scope %></span> ·
                Formation: <span class="font-mono text-xs text-indigo-400"><%= @active_run.formation_id %></span>
              </div>
            </div>

            <div class="flex gap-2">
              <%= if @active_run.status == :awaiting_gate do %>
                <button
                  phx-click="apply_run"
                  phx-value-run_id={@active_run.run_id}
                  class="px-3 py-1.5 bg-emerald-600 hover:bg-emerald-500 text-white text-sm rounded transition-colors"
                >
                  Apply Diffs
                </button>
              <% end %>

              <%= if @active_run.status in [:intelligence, :analysis, :generation, :validation, :awaiting_gate] do %>
                <button
                  phx-click="cancel_run"
                  phx-value-run_id={@active_run.run_id}
                  class="px-3 py-1.5 bg-zinc-700 hover:bg-zinc-600 text-zinc-300 text-sm rounded transition-colors"
                >
                  Cancel
                </button>
              <% end %>
            </div>
          </div>

          <!-- Gate Panel -->
          <%= if length(@active_run_gates) > 0 do %>
            <div class="p-4 border-b border-zinc-800 bg-zinc-900/50">
              <h3 class="text-xs font-semibold text-zinc-400 uppercase tracking-wider mb-3">Decision Gates</h3>
              <div class="flex gap-3 flex-wrap">
                <%= for gate <- @active_run_gates do %>
                  <div class={"flex items-center gap-2 px-3 py-2 rounded-lg border #{_gate_border_color(gate.status)}"}>
                    <div class={"w-2 h-2 rounded-full #{_gate_dot_color(gate.status)}"}></div>
                    <span class="text-sm font-mono"><%= gate.gate_id %></span>
                    <span class="text-xs text-zinc-500"><%= gate.type %></span>

                    <%= if gate.status == :pending and gate.type == :human do %>
                      <div class="flex gap-1 ml-2">
                        <button
                          phx-click="gate_approve"
                          phx-value-composite_id={gate.composite_id}
                          class="text-xs px-2 py-0.5 bg-emerald-700 hover:bg-emerald-600 text-white rounded"
                        >Approve</button>
                        <button
                          phx-click="gate_reject"
                          phx-value-composite_id={gate.composite_id}
                          phx-value-reason="rejected from dashboard"
                          class="text-xs px-2 py-0.5 bg-red-700 hover:bg-red-600 text-white rounded"
                        >Reject</button>
                        <button
                          phx-click="gate_defer"
                          phx-value-composite_id={gate.composite_id}
                          class="text-xs px-2 py-0.5 bg-zinc-700 hover:bg-zinc-600 text-zinc-300 rounded"
                        >Defer</button>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <!-- Diffs List -->
          <div class="flex-1 overflow-y-auto p-4">
            <h3 class="text-xs font-semibold text-zinc-400 uppercase tracking-wider mb-3">
              Proposed Skill Diffs (<%= length(@active_run.diffs) %>)
            </h3>

            <div class="grid grid-cols-1 gap-2">
              <%= for diff <- @active_run.diffs do %>
                <div
                  class="flex items-center justify-between px-4 py-3 bg-zinc-900 border border-zinc-800 rounded-lg hover:border-zinc-600 cursor-pointer transition-colors"
                  phx-click="select_diff"
                  phx-value-skill={diff.skill_name}
                >
                  <div class="flex items-center gap-3">
                    <span class={"text-xs px-1.5 py-0.5 rounded #{_impact_color(diff.impact)}"}>
                      <%= diff.impact %>
                    </span>
                    <span class="text-sm font-mono text-zinc-200"><%= diff.skill_name %></span>
                    <span class="text-xs text-zinc-500"><%= length(diff.additions) %> additions</span>
                  </div>
                  <div class="flex items-center gap-3">
                    <span class="text-xs text-zinc-400">
                      confidence: <span class={_confidence_color(diff.confidence)}><%= Float.round(diff.confidence * 100, 0) |> trunc() %>%</span>
                    </span>
                    <span class={"text-xs px-1.5 py-0.5 rounded #{if diff.approved, do: "bg-emerald-900/50 text-emerald-400", else: "bg-zinc-800 text-zinc-500"}"}>
                      <%= if diff.approved, do: "approved", else: "pending" %>
                    </span>
                  </div>
                </div>
              <% end %>

              <%= if Enum.empty?(@active_run.diffs) do %>
                <div class="text-center py-8 text-zinc-600 text-sm">
                  <%= if @active_run.status in [:intelligence, :analysis] do %>
                    Generation in progress...
                  <% else %>
                    No diffs generated
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

        <% else %>
          <div class="flex-1 flex items-center justify-center">
            <div class="text-center text-zinc-600">
              <div class="text-4xl mb-4">⟐</div>
              <div class="text-lg">No active run</div>
              <div class="text-sm mt-2">Start one with <code class="text-indigo-400">/coalesce &lt;url&gt;</code></div>
            </div>
          </div>
        <% end %>
      </div>

      <!-- Right: Diff Viewer -->
      <%= if @selected_diff do %>
        <div class="w-[480px] border-l border-zinc-800 flex flex-col">
          <div class="p-4 border-b border-zinc-800 flex items-center justify-between">
            <h3 class="text-sm font-semibold font-mono text-indigo-400"><%= @selected_diff.skill_name %></h3>
            <button phx-click="close_diff" class="text-zinc-500 hover:text-zinc-300">✕</button>
          </div>
          <div class="flex-1 overflow-y-auto p-4">
            <div class="space-y-4">
              <%= for addition <- @selected_diff.additions do %>
                <div class="bg-zinc-900 border border-zinc-700 rounded-lg p-3">
                  <div class="flex items-center gap-2 mb-2">
                    <span class="text-xs px-1.5 py-0.5 bg-emerald-900/50 text-emerald-400 rounded"><%= addition.type %></span>
                    <span class="text-sm font-semibold text-zinc-200"><%= addition.section %></span>
                  </div>
                  <pre class="text-xs text-zinc-400 whitespace-pre-wrap font-mono overflow-x-auto"><%= addition.content %></pre>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
      </div>
      </div>
    </div>
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

  defp _status_color(:intelligence), do: "bg-blue-900/60 text-blue-300"
  defp _status_color(:analysis), do: "bg-purple-900/60 text-purple-300"
  defp _status_color(:generation), do: "bg-indigo-900/60 text-indigo-300"
  defp _status_color(:validation), do: "bg-amber-900/60 text-amber-300"
  defp _status_color(:awaiting_gate), do: "bg-orange-900/60 text-orange-300"
  defp _status_color(:applying), do: "bg-emerald-900/60 text-emerald-400"
  defp _status_color(:complete), do: "bg-emerald-900/60 text-emerald-400"
  defp _status_color(:cancelled), do: "bg-zinc-800 text-zinc-500"
  defp _status_color(:failed), do: "bg-red-900/60 text-red-400"
  defp _status_color(_), do: "bg-zinc-800 text-zinc-400"

  defp _gate_border_color(:pending), do: "border-orange-700 bg-orange-900/20"
  defp _gate_border_color(:approved), do: "border-emerald-700 bg-emerald-900/20"
  defp _gate_border_color(:rejected), do: "border-red-700 bg-red-900/20"
  defp _gate_border_color(:deferred), do: "border-zinc-600 bg-zinc-800/50"
  defp _gate_border_color(_), do: "border-zinc-700 bg-zinc-800/50"

  defp _gate_dot_color(:pending), do: "bg-orange-400 animate-pulse"
  defp _gate_dot_color(:approved), do: "bg-emerald-400"
  defp _gate_dot_color(:rejected), do: "bg-red-400"
  defp _gate_dot_color(_), do: "bg-zinc-500"

  defp _impact_color(:high), do: "bg-red-900/60 text-red-400"
  defp _impact_color(:medium), do: "bg-amber-900/60 text-amber-400"
  defp _impact_color(:low), do: "bg-zinc-800 text-zinc-400"
  defp _impact_color(_), do: "bg-zinc-800 text-zinc-400"

  defp _confidence_color(c) when c >= 0.85, do: "text-emerald-400"
  defp _confidence_color(c) when c >= 0.70, do: "text-amber-400"
  defp _confidence_color(_), do: "text-red-400"
end
