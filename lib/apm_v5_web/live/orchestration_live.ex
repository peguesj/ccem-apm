defmodule ApmV5Web.OrchestrationLive do
  @moduledoc """
  LiveView for the Orchestration System dashboard.

  Displays active and historical orchestration runs with D3.js DAG
  visualization. Subscribes to `apm:orchestration` PubSub for real-time
  updates.

  ## Sections

  - Active runs table with status, progress, and timing
  - Run detail view with D3.js DAG (click to expand)
  - Step inspector panel (click step for payload/result/timing)
  - History tab with completed runs and replay button
  - Dry-run button (preview execution plan)
  """

  use ApmV5Web, :live_view

  alias ApmV5.Orchestration.OrchestrationManager
  alias ApmV5.Orchestration.OrchestrationRunStore
  alias ApmV5.WorkflowRegistry

  @pubsub_topic "apm:orchestration"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic)
    end

    active_runs = OrchestrationManager.list_all_runs()
    history = OrchestrationRunStore.list_runs(limit: 20)
    workflows = WorkflowRegistry.list_workflows()

    socket =
      socket
      |> assign(:page_title, "Orchestration")
      |> assign(:active_runs, active_runs)
      |> assign(:history, history)
      |> assign(:workflows, workflows)
      |> assign(:selected_run, nil)
      |> assign(:selected_step, nil)
      |> assign(:tab, "active")
      |> assign(:notification_count, 0)
      |> assign(:skill_count, 0)
      |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-100">
      <ApmV5Web.Components.SidebarNav.sidebar_nav
        current_path="/orchestration"
        notification_count={@notification_count}
        skill_count={@skill_count}
        plugins={@plugins}
        integrations={@integrations}
      />
      <main class="flex-1 overflow-auto p-6">
        <div class="max-w-7xl mx-auto">
          <div class="flex items-center justify-between mb-6">
            <div>
              <h1 class="text-2xl font-bold text-base-content">Orchestration</h1>
              <p class="text-sm text-base-content/60 mt-1">DAG-based workflow execution engine</p>
            </div>
            <div class="flex gap-2">
              <button phx-click="start_dry_run" class="btn btn-outline btn-sm">
                <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z" />
                </svg>
                Dry Run
              </button>
            </div>
          </div>

          <%!-- Tab bar --%>
          <div class="tabs tabs-bordered mb-4">
            <a class={"tab #{if @tab == "active", do: "tab-active"}"} phx-click="switch_tab" phx-value-tab="active">
              Active Runs
              <span :if={length(@active_runs) > 0} class="badge badge-sm badge-primary ml-1">{length(@active_runs)}</span>
            </a>
            <a class={"tab #{if @tab == "history", do: "tab-active"}"} phx-click="switch_tab" phx-value-tab="history">
              History
              <span :if={length(@history) > 0} class="badge badge-sm badge-ghost ml-1">{length(@history)}</span>
            </a>
            <a class={"tab #{if @tab == "workflows", do: "tab-active"}"} phx-click="switch_tab" phx-value-tab="workflows">
              Workflows
            </a>
          </div>

          <%!-- Active runs --%>
          <div :if={@tab == "active"}>
            <div :if={@active_runs == []} class="text-center py-12 text-base-content/40">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-12 w-12 mx-auto mb-3 opacity-30" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M9 17V7m0 10a2 2 0 01-2 2H5a2 2 0 01-2-2V7a2 2 0 012-2h2a2 2 0 012 2m0 10a2 2 0 002 2h2a2 2 0 002-2M9 7a2 2 0 012-2h2a2 2 0 012 2m0 10V7" />
              </svg>
              <p class="font-medium">No active orchestration runs</p>
              <p class="text-sm mt-1">Start a run from a workflow or use the API</p>
            </div>

            <div :if={@active_runs != []} class="space-y-3">
              <div
                :for={run <- @active_runs}
                class={"card bg-base-200 shadow-sm cursor-pointer hover:bg-base-300 transition-colors #{if @selected_run && @selected_run.id == run.id, do: "ring-2 ring-primary"}"}
                phx-click="select_run"
                phx-value-id={run.id}
              >
                <div class="card-body p-4">
                  <div class="flex items-center justify-between">
                    <div class="flex items-center gap-3">
                      <.status_badge status={run.status} />
                      <div>
                        <span class="font-mono text-sm font-medium">{run.id}</span>
                        <span class="text-xs text-base-content/50 ml-2">({run.workflow_id})</span>
                      </div>
                    </div>
                    <div class="flex items-center gap-4 text-xs text-base-content/50">
                      <span>{format_progress(run)}</span>
                      <span>{format_time(run.created_at)}</span>
                    </div>
                  </div>
                  <.progress_bar run={run} />
                </div>
              </div>
            </div>
          </div>

          <%!-- History --%>
          <div :if={@tab == "history"}>
            <div :if={@history == []} class="text-center py-12 text-base-content/40">
              <p class="font-medium">No historical runs</p>
            </div>

            <table :if={@history != []} class="table table-sm w-full">
              <thead>
                <tr>
                  <th>Run ID</th>
                  <th>Workflow</th>
                  <th>Status</th>
                  <th>Steps</th>
                  <th>Created</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={run <- @history} class="hover">
                  <td class="font-mono text-xs">{run.id}</td>
                  <td>{run.workflow_id}</td>
                  <td><.status_badge status={run.status} /></td>
                  <td>{format_progress(run)}</td>
                  <td class="text-xs">{format_time(run.created_at)}</td>
                  <td>
                    <button phx-click="replay_run" phx-value-id={run.id} class="btn btn-xs btn-ghost">
                      Replay
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <%!-- Workflows --%>
          <div :if={@tab == "workflows"}>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
              <div :for={wf <- @workflows} class="card bg-base-200 shadow-sm">
                <div class="card-body p-4">
                  <h3 class="card-title text-sm">{wf[:title] || wf.id}</h3>
                  <p class="text-xs text-base-content/60">{wf[:description] || ""}</p>
                  <div class="text-xs text-base-content/40 mt-1">
                    {length(wf[:steps] || [])} steps, {length(wf[:edges] || [])} edges
                  </div>
                  <div class="card-actions justify-end mt-2">
                    <button phx-click="start_run" phx-value-workflow={wf.id} class="btn btn-xs btn-primary">
                      Start Run
                    </button>
                    <button phx-click="dry_run_workflow" phx-value-workflow={wf.id} class="btn btn-xs btn-ghost">
                      Dry Run
                    </button>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <%!-- Selected run detail with DAG --%>
          <div :if={@selected_run} class="mt-6">
            <div class="divider text-xs text-base-content/40">RUN DETAIL</div>
            <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
              <%!-- DAG visualization --%>
              <div class="lg:col-span-2">
                <div class="card bg-base-200 shadow-sm">
                  <div class="card-body p-4">
                    <h3 class="text-sm font-medium mb-2">Execution DAG</h3>
                    <div
                      id="orchestration-dag"
                      phx-hook="OrchestrationGraph"
                      phx-update="ignore"
                      data-run={Jason.encode!(%{
                        steps: Map.values(@selected_run.steps),
                        edges: @selected_run.edges
                      })}
                      class="w-full h-96 bg-base-300 rounded-lg"
                    >
                    </div>
                  </div>
                </div>
              </div>

              <%!-- Step inspector --%>
              <div>
                <div class="card bg-base-200 shadow-sm">
                  <div class="card-body p-4">
                    <h3 class="text-sm font-medium mb-2">Step Inspector</h3>
                    <div :if={@selected_step == nil} class="text-center py-8 text-base-content/40 text-sm">
                      Click a step in the DAG to inspect
                    </div>
                    <div :if={@selected_step}>
                      <div class="space-y-2 text-sm">
                        <div>
                          <span class="text-base-content/50">ID:</span>
                          <span class="font-mono ml-1">{@selected_step.id}</span>
                        </div>
                        <div>
                          <span class="text-base-content/50">Status:</span>
                          <.status_badge status={@selected_step.status} />
                        </div>
                        <div :if={@selected_step.started_at}>
                          <span class="text-base-content/50">Started:</span>
                          <span class="text-xs ml-1">{format_time(@selected_step.started_at)}</span>
                        </div>
                        <div :if={@selected_step.completed_at}>
                          <span class="text-base-content/50">Completed:</span>
                          <span class="text-xs ml-1">{format_time(@selected_step.completed_at)}</span>
                        </div>
                        <div :if={@selected_step.result}>
                          <span class="text-base-content/50">Result:</span>
                          <pre class="text-xs bg-base-300 p-2 rounded mt-1 overflow-x-auto"><%= Jason.encode!(@selected_step.result, pretty: true) %></pre>
                        </div>
                        <div :if={@selected_step.payload && @selected_step.payload != %{}}>
                          <span class="text-base-content/50">Payload:</span>
                          <pre class="text-xs bg-base-300 p-2 rounded mt-1 overflow-x-auto"><%= Jason.encode!(@selected_step.payload, pretty: true) %></pre>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </main>
    </div>
    """
  end

  # ── Event Handlers ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :tab, tab)}
  end

  def handle_event("select_run", %{"id" => id}, socket) do
    run = OrchestrationManager.get_run(id) || find_in_history(id, socket.assigns.history)

    {:noreply,
     socket
     |> assign(:selected_run, run)
     |> assign(:selected_step, nil)}
  end

  def handle_event("select_step", %{"step_id" => step_id}, socket) do
    step =
      case socket.assigns.selected_run do
        nil -> nil
        run -> Map.get(run.steps, step_id)
      end

    {:noreply, assign(socket, :selected_step, step)}
  end

  def handle_event("start_run", %{"workflow" => workflow_id}, socket) do
    case OrchestrationManager.start_run(workflow_id) do
      {:ok, run} ->
        {:noreply,
         socket
         |> assign(:active_runs, OrchestrationManager.list_all_runs())
         |> assign(:selected_run, run)
         |> put_flash(:info, "Started run #{run.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start run: #{inspect(reason)}")}
    end
  end

  def handle_event("start_dry_run", _params, socket) do
    # Pick first available workflow for dry run demo
    case List.first(socket.assigns.workflows) do
      nil ->
        {:noreply, put_flash(socket, :error, "No workflows available")}

      wf ->
        case OrchestrationManager.start_run(wf.id, %{dry_run: true}) do
          {:ok, dry_result} ->
            {:noreply,
             socket
             |> assign(:selected_run, dry_result)
             |> put_flash(:info, "Dry run complete — see execution order")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Dry run failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("dry_run_workflow", %{"workflow" => workflow_id}, socket) do
    case OrchestrationManager.start_run(workflow_id, %{dry_run: true}) do
      {:ok, dry_result} ->
        {:noreply,
         socket
         |> assign(:selected_run, dry_result)
         |> put_flash(:info, "Dry run for #{workflow_id} complete")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Dry run failed: #{inspect(reason)}")}
    end
  end

  def handle_event("replay_run", %{"id" => id}, socket) do
    case OrchestrationRunStore.replay_run(id) do
      {:ok, new_run} ->
        {:noreply,
         socket
         |> assign(:active_runs, OrchestrationManager.list_all_runs())
         |> assign(:selected_run, new_run)
         |> assign(:tab, "active")
         |> put_flash(:info, "Replayed as #{new_run.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Replay failed: #{inspect(reason)}")}
    end
  end

  # ── PubSub Handlers ────────────────────────────────────────────────────────

  @impl true
  def handle_info({event, _payload}, socket)
      when event in [
             :run_started,
             :run_completed,
             :run_cancelled,
             :step_completed,
             :step_failed,
             :step_skipped
           ] do
    active_runs = OrchestrationManager.list_all_runs()
    history = OrchestrationRunStore.list_runs(limit: 20)

    selected_run =
      case socket.assigns.selected_run do
        nil -> nil
        %{id: id} -> OrchestrationManager.get_run(id) || find_in_history(id, history)
      end

    {:noreply,
     socket
     |> assign(:active_runs, active_runs)
     |> assign(:history, history)
     |> assign(:selected_run, selected_run)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp find_in_history(id, history) do
    Enum.find(history, fn run -> run.id == id end)
  end

  defp format_progress(run) do
    total = map_size(run.steps)
    done = Enum.count(run.steps, fn {_id, s} -> s.status in [:completed, :skipped] end)
    "#{done}/#{total}"
  end

  defp format_time(nil), do: "-"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_time(_), do: "-"

  defp status_badge(assigns) do
    {color, label} =
      case assigns.status do
        :pending -> {"badge-ghost", "pending"}
        :running -> {"badge-info", "running"}
        :completed -> {"badge-success", "completed"}
        :failed -> {"badge-error", "failed"}
        :cancelled -> {"badge-warning", "cancelled"}
        :skipped -> {"badge-ghost", "skipped"}
        other -> {"badge-ghost", to_string(other)}
      end

    assigns = assign(assigns, color: color, label: label)

    ~H"""
    <span class={"badge badge-xs #{@color}"}>{@label}</span>
    """
  end

  defp progress_bar(assigns) do
    total = map_size(assigns.run.steps)

    {completed, failed, running} =
      Enum.reduce(assigns.run.steps, {0, 0, 0}, fn {_id, s}, {c, f, r} ->
        case s.status do
          :completed -> {c + 1, f, r}
          :skipped -> {c + 1, f, r}
          :failed -> {c, f + 1, r}
          :running -> {c, f, r + 1}
          _ -> {c, f, r}
        end
      end)

    pct_completed = if total > 0, do: round(completed / total * 100), else: 0
    pct_failed = if total > 0, do: round(failed / total * 100), else: 0
    pct_running = if total > 0, do: round(running / total * 100), else: 0

    assigns =
      assign(assigns,
        pct_completed: pct_completed,
        pct_failed: pct_failed,
        pct_running: pct_running
      )

    ~H"""
    <div class="w-full bg-base-300 rounded-full h-1.5 mt-2">
      <div class="flex h-full rounded-full overflow-hidden">
        <div class="bg-success h-full" style={"width: #{@pct_completed}%"}></div>
        <div class="bg-info h-full" style={"width: #{@pct_running}%"}></div>
        <div class="bg-error h-full" style={"width: #{@pct_failed}%"}></div>
      </div>
    </div>
    """
  end
end
