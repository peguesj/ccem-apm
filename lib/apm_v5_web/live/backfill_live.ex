defmodule ApmV5Web.BackfillLive do
  use ApmV5Web, :live_view
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(10_000, self(), :refresh)
    end
    {:ok, assign_data(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_event("sync_to_plane", _params, socket) do
    socket = assign(socket, :syncing, true)
    Task.start(fn ->
      ApmV5.BackfillRunner.run_primary()
    end)
    {:noreply, socket}
  end

  @impl true
  def handle_event("check_api", _params, socket) do
    result = ApmV5.BackfillRunner.check_api_connection()
    message = case result do
      {:ok, msg} -> "Connected: #{msg}"
      {:error, msg} -> "Error: #{msg}"
    end
    {:noreply, assign(socket, :api_message, message)}
  end

  @impl true
  def handle_event("insert_rule", _params, socket) do
    result = ApmV5.UpmPersistentRule.insert_rule()
    message = case result do
      {:ok, msg} -> msg
      {:error, msg} -> "Error: #{msg}"
    end
    {:noreply, socket |> assign(:rule_message, message) |> assign_data()}
  end

  defp assign_data(socket) do
    store = ApmV5.BackfillStore.get_state()
    prd_files = ApmV5.PrdScanner.scan()
    rule_status = ApmV5.UpmPersistentRule.check_rule()
    assign(socket,
      store: store,
      prd_files: prd_files,
      rule_status: rule_status,
      syncing: false,
      api_message: Map.get(socket.assigns, :api_message),
      rule_message: Map.get(socket.assigns, :rule_message),
      page_title: "Backfill"
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-100 overflow-hidden">
      <.sidebar_nav current_path="/backfill" />

      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="bg-base-200 border-b border-base-300 px-4 py-2 flex items-center justify-between flex-shrink-0">
          <h1 class="font-semibold text-sm">UPM → Plane Backfill</h1>
          <div class="flex gap-2">
            <button phx-click="check_api" class="btn btn-xs btn-ghost gap-1">
              <.icon name="hero-signal" class="size-3.5" /> Check API
            </button>
            <button phx-click="sync_to_plane" disabled={@syncing} class="btn btn-xs btn-primary gap-1">
              <.icon name={if @syncing, do: "hero-arrow-path", else: "hero-arrow-up-tray"} class={["size-3.5", @syncing && "animate-spin"]} />
              {if @syncing, do: "Syncing...", else: "Sync to Plane"}
            </button>
          </div>
        </header>

        <div class="flex-1 overflow-y-auto p-4 space-y-4">
          <%!-- API Status Message --%>
          <div :if={@api_message} class="alert alert-sm alert-info text-xs">
            <.icon name="hero-signal" class="size-4" />
            <span>{@api_message}</span>
          </div>

          <%!-- UPM Rule Status --%>
          <div class="bg-base-200 rounded-lg p-4">
            <div class="flex items-center justify-between mb-2">
              <h2 class="text-sm font-semibold">UPM→APM Integration Rule</h2>
              <span class={["badge badge-sm", rule_badge_class(@rule_status)]}>
                {rule_label(@rule_status)}
              </span>
            </div>
            <div :if={match?({:absent, _}, @rule_status)} class="flex items-center gap-2">
              <span class="text-xs text-base-content/60">Rule not found in ~/.claude/CLAUDE.md</span>
              <button phx-click="insert_rule" class="btn btn-xs btn-warning gap-1">
                <.icon name="hero-plus" class="size-3" /> Insert Rule
              </button>
            </div>
            <div :if={match?({:present, _}, @rule_status)} class="text-xs text-success">
              Rule is present in ~/.claude/CLAUDE.md
            </div>
            <div :if={@rule_message} class="mt-1 text-xs text-base-content/60">{@rule_message}</div>
          </div>

          <%!-- prd.json Files --%>
          <div class="bg-base-200 rounded-lg p-4">
            <h2 class="text-sm font-semibold mb-3">prd.json Files ({length(@prd_files)})</h2>
            <div :if={@prd_files == []} class="text-xs text-base-content/40">No prd.json files found</div>
            <div class="overflow-x-auto">
              <table class="table table-xs w-full">
                <thead>
                  <tr>
                    <th>Project</th>
                    <th>Branch</th>
                    <th>Stories</th>
                    <th>Passes</th>
                    <th>Pending</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={prd <- @prd_files}>
                    <td class="font-medium">{prd.project}</td>
                    <td class="font-mono text-xs">{prd.branch}</td>
                    <td>{prd.total_stories}</td>
                    <td><span class="badge badge-xs badge-success">{prd.passes}</span></td>
                    <td><span class="badge badge-xs badge-warning">{prd.pending}</span></td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <%!-- Run History --%>
          <div class="bg-base-200 rounded-lg p-4">
            <h2 class="text-sm font-semibold mb-3">Backfill History ({length(@store.runs)})</h2>
            <div :if={@store.runs == []} class="text-xs text-base-content/40">No runs yet. Click "Sync to Plane" to start.</div>
            <div class="space-y-2">
              <div :for={run <- Enum.take(@store.runs, 10)} class={["rounded p-2 text-xs border-l-4", run_border_class(run)]}>
                <div class="flex items-center justify-between">
                  <span class={["badge badge-xs", run_badge_class(run)]}>{run[:status]}</span>
                  <span class="text-base-content/40">{format_dt(run[:started_at])}</span>
                </div>
                <div :if={run[:message]} class="mt-1 text-base-content/60">{run[:message]}</div>
                <div :if={run[:synced]} class="mt-1 text-base-content/60">
                  {Enum.count(run[:synced], &(&1.status == :synced))} synced /
                  {Enum.count(run[:synced], &(&1.status == :error))} errors
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp rule_badge_class({:present, _}), do: "badge-success"
  defp rule_badge_class({:absent, _}), do: "badge-warning"
  defp rule_badge_class(_), do: "badge-ghost"

  defp rule_label({:present, _}), do: "present"
  defp rule_label({:absent, _}), do: "absent"
  defp rule_label(_), do: "unknown"

  defp run_border_class(%{status: :ok}), do: "border-success"
  defp run_border_class(%{status: :error}), do: "border-error"
  defp run_border_class(%{status: :running}), do: "border-warning"
  defp run_border_class(_), do: "border-base-300"

  defp run_badge_class(%{status: :ok}), do: "badge-success"
  defp run_badge_class(%{status: :error}), do: "badge-error"
  defp run_badge_class(%{status: :running}), do: "badge-warning"
  defp run_badge_class(_), do: "badge-ghost"

  defp format_dt(nil), do: "?"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%m/%d %H:%M:%S")
  defp format_dt(_), do: "?"
end
