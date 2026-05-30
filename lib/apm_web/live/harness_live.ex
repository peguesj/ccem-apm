defmodule ApmWeb.HarnessLive do
  @moduledoc """
  LiveView for the Claude Code Harness plugin at `/plugins/harness`.

  Three tabs:
  - **Health** — harness-mem status, plans count, git branch, session state, worktree count.
  - **Hooks** — recent hook telemetry events table with per-event-type stats.
  - **Session** — raw session state as formatted JSON.

  Subscribes to `"harness:state"` PubSub for live updates and polls every 15 s.
  """

  use ApmWeb, :live_view

  require Logger

  alias Apm.Plugins.Harness.HarnessMonitor
  alias Apm.Plugins.Harness.HookTelemetryBuffer

  @pubsub_topic "harness:state"
  @refresh_interval_ms 15_000
  @default_hook_limit 50

  # ── Mount ──────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Apm.PubSub, @pubsub_topic)
      :timer.send_interval(@refresh_interval_ms, self(), :refresh)
    end

    {harness_state, hook_events, hook_stats} = load_all(@default_hook_limit)

    socket =
      socket
      |> assign(:page_title, "Harness")
      |> assign(:harness_state, harness_state)
      |> assign(:hook_events, hook_events)
      |> assign(:hook_stats, hook_stats)
      |> assign(:hook_limit, @default_hook_limit)
      |> assign(:active_tab, "health")
      |> assign(:notification_count, 0)
      |> assign(:skill_count, 0)
      |> assign(:sidebar_collapsed, false)
     |> assign(:inspector_open, false)
     |> ApmWeb.Components.SidebarNav.assign_sidebar_nav_data()

    {:ok, socket}
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <ApmWeb.Components.SidebarNav.sidebar_nav
        current_path="/plugins/harness"
        notification_count={@notification_count}
        skill_count={@skill_count}
        plugins={@plugins}
        integrations={@integrations}
        />
      </:sidebar>
      <:main>
      <main class="flex-1 overflow-auto p-6">
        <div class="max-w-7xl mx-auto">
          <%!-- Header --%>
          <div class="flex items-center justify-between mb-6">
            <div>
              <h1 class="text-2xl font-bold text-base-content">Claude Code Harness</h1>
              <p class="text-sm text-base-content/60 mt-1">
                Hook telemetry, session state, and plan tracking
              </p>
            </div>
          </div>

          <%!-- Tab bar --%>
          <div class="tabs tabs-bordered mb-4">
            <a
              class={"tab #{if @active_tab == "health", do: "tab-active"}"}
              phx-click="switch_tab"
              phx-value-tab="health"
            >
              Health
            </a>
            <a
              class={"tab #{if @active_tab == "hooks", do: "tab-active"}"}
              phx-click="switch_tab"
              phx-value-tab="hooks"
            >
              Hooks
            </a>
            <a
              class={"tab #{if @active_tab == "session", do: "tab-active"}"}
              phx-click="switch_tab"
              phx-value-tab="session"
            >
              Session
            </a>
          </div>

          <%!-- Health tab --%>
          <div :if={@active_tab == "health"}>
            <div :if={is_nil(@harness_state)} class="text-center py-12 text-base-content/40">
              <p class="font-medium">No data</p>
              <p class="text-sm mt-1">HarnessMonitor is not running</p>
            </div>

            <div :if={!is_nil(@harness_state)} class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <%!-- Status card --%>
              <div class="card bg-base-200 shadow-sm">
                <div class="card-body p-4">
                  <h2 class="card-title text-sm font-semibold text-base-content/70">harness-mem</h2>
                  <div class="flex items-center gap-2 mt-1">
                    <span class={"badge #{harness_status_badge(@harness_state)}"}>
                      {harness_status_label(@harness_state)}
                    </span>
                  </div>
                </div>
              </div>

              <%!-- Git branch --%>
              <div class="card bg-base-200 shadow-sm">
                <div class="card-body p-4">
                  <h2 class="card-title text-sm font-semibold text-base-content/70">Git Branch</h2>
                  <p class="text-sm font-mono text-base-content mt-1">
                    {get_in(@harness_state, ["git_branch"]) || get_in(@harness_state, [:git_branch]) || "—"}
                  </p>
                </div>
              </div>

              <%!-- Plans count --%>
              <div class="card bg-base-200 shadow-sm">
                <div class="card-body p-4">
                  <h2 class="card-title text-sm font-semibold text-base-content/70">Plans</h2>
                  <p class="text-2xl font-bold text-base-content mt-1">
                    {get_in(@harness_state, ["plans_count"]) || get_in(@harness_state, [:plans_count]) || 0}
                  </p>
                </div>
              </div>

              <%!-- Worktree count --%>
              <div class="card bg-base-200 shadow-sm">
                <div class="card-body p-4">
                  <h2 class="card-title text-sm font-semibold text-base-content/70">Worktrees</h2>
                  <p class="text-2xl font-bold text-base-content mt-1">
                    {get_in(@harness_state, ["worktree_count"]) || get_in(@harness_state, [:worktree_count]) || 0}
                  </p>
                </div>
              </div>

              <%!-- Session state --%>
              <div class="card bg-base-200 shadow-sm md:col-span-2">
                <div class="card-body p-4">
                  <h2 class="card-title text-sm font-semibold text-base-content/70">Session State</h2>
                  <span class={"badge badge-sm mt-1 #{session_state_badge(@harness_state)}"}>
                    {get_in(@harness_state, ["session_state"]) || get_in(@harness_state, [:session_state]) || "unknown"}
                  </span>
                </div>
              </div>
            </div>
          </div>

          <%!-- Hooks tab --%>
          <div :if={@active_tab == "hooks"}>
            <div class="flex items-center justify-between mb-4">
              <div class="flex items-center gap-3">
                <span class="text-sm text-base-content/60">
                  Total: <span class="font-semibold text-base-content">{@hook_stats[:total] || 0}</span>
                </span>
                <div class="flex gap-1 flex-wrap">
                  <span
                    :for={{event_name, count} <- (@hook_stats[:by_event] || %{})}
                    class="badge badge-sm badge-ghost font-mono"
                  >
                    {event_name}: {count}
                  </span>
                </div>
              </div>
              <div class="flex gap-2">
                <button class="btn btn-sm btn-ghost" phx-click="refresh_hooks">
                  Refresh
                </button>
                <button class="btn btn-sm btn-error btn-outline" phx-click="clear_hooks">
                  Clear
                </button>
              </div>
            </div>

            <div :if={@hook_events == []} class="text-center py-12 text-base-content/40">
              <p class="font-medium">No hook events</p>
              <p class="text-sm mt-1">Events will appear as Claude Code tools are invoked</p>
            </div>

            <div :if={@hook_events != []}>
              <div class="overflow-x-auto">
                <table class="table table-sm w-full">
                  <thead>
                    <tr>
                      <th class="text-xs text-base-content/50 uppercase">Event Type</th>
                      <th class="text-xs text-base-content/50 uppercase">Tool / Name</th>
                      <th class="text-xs text-base-content/50 uppercase">Timestamp</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={event <- @hook_events} class="hover">
                      <td>
                        <span class={"badge badge-sm #{hook_event_badge(event)}"}>
                          {hook_event_type(event)}
                        </span>
                      </td>
                      <td class="font-mono text-xs text-base-content truncate max-w-xs">
                        {hook_event_name(event)}
                      </td>
                      <td class="text-xs text-base-content/50 font-mono">
                        {hook_event_timestamp(event)}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>

          <%!-- Session tab --%>
          <div :if={@active_tab == "session"}>
            <div :if={is_nil(@harness_state)} class="text-center py-12 text-base-content/40">
              <p class="font-medium">No data</p>
              <p class="text-sm mt-1">HarnessMonitor is not running</p>
            </div>

            <div :if={!is_nil(@harness_state)}>
              <pre class="text-xs font-mono bg-base-200 rounded-lg p-4 overflow-x-auto whitespace-pre-wrap break-words max-h-screen-3/4 overflow-y-auto leading-relaxed">
                {Jason.encode!(@harness_state, pretty: true)}
              </pre>
            </div>
          </div>
        </div>
      </main>
      </:main>
    </.page_layout>
    """
  end

  # ── Event Handlers ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket)
      when tab in ["health", "hooks", "session"] do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("switch_tab", _params, socket), do: {:noreply, socket}

  def handle_event("refresh_hooks", _params, socket) do
    events = safe_recent(socket.assigns.hook_limit)
    stats = safe_stats()
    {:noreply, assign(socket, hook_events: events, hook_stats: stats)}
  end

  def handle_event("clear_hooks", _params, socket) do
    safe_clear()
    events = safe_recent(socket.assigns.hook_limit)
    stats = safe_stats()
    {:noreply, assign(socket, hook_events: events, hook_stats: stats)}
  end

  # ── PubSub / Internal Messages ─────────────────────────────────────────────

  @impl true
  def handle_info({:harness_state_updated, state}, socket) do
    {:noreply, assign(socket, :harness_state, state)}
  end

  def handle_info(:refresh, socket) do
    {harness_state, hook_events, hook_stats} = load_all(socket.assigns.hook_limit)

    {:noreply,
     assign(socket,
       harness_state: harness_state,
       hook_events: hook_events,
       hook_stats: hook_stats
     )}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec load_all(pos_integer()) :: {map() | nil, list(), map()}
  defp load_all(limit) do
    harness_state = safe_current_state()
    hook_events = safe_recent(limit)
    hook_stats = safe_stats()
    {harness_state, hook_events, hook_stats}
  end

  @spec safe_current_state() :: map() | nil
  defp safe_current_state do
    HarnessMonitor.current_state()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @spec safe_recent(pos_integer()) :: list()
  defp safe_recent(limit) do
    HookTelemetryBuffer.recent(limit)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @spec safe_stats() :: map()
  defp safe_stats do
    HookTelemetryBuffer.stats()
  rescue
    _ -> %{total: 0, by_event: %{}}
  catch
    :exit, _ -> %{total: 0, by_event: %{}}
  end

  defp safe_clear do
    HookTelemetryBuffer.clear()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp harness_status_badge(state) do
    case get_in(state, ["healthy"]) || get_in(state, [:healthy]) do
      true -> "badge-success"
      false -> "badge-error"
      _ -> "badge-warning"
    end
  end

  defp harness_status_label(state) do
    case get_in(state, ["healthy"]) || get_in(state, [:healthy]) do
      true -> "healthy"
      false -> "unhealthy"
      _ -> "unknown"
    end
  end

  defp session_state_badge(state) do
    case get_in(state, ["session_state"]) || get_in(state, [:session_state]) do
      "active" -> "badge-success"
      "idle" -> "badge-ghost"
      "error" -> "badge-error"
      _ -> "badge-warning"
    end
  end

  defp hook_event_type(event) do
    to_string(
      Map.get(event, "event_type") || Map.get(event, :event_type) ||
        Map.get(event, "event") || Map.get(event, :event) || "unknown"
    )
  end

  defp hook_event_badge(event) do
    case hook_event_type(event) do
      "PreToolUse" -> "badge-info"
      "PostToolUse" -> "badge-success"
      "PreToolUseBlock" -> "badge-error"
      "Notification" -> "badge-warning"
      "Stop" -> "badge-ghost"
      _ -> "badge-ghost"
    end
  end

  defp hook_event_name(event) do
    Map.get(event, "tool_name") || Map.get(event, :tool_name) ||
      Map.get(event, "name") || Map.get(event, :name) || "—"
  end

  defp hook_event_timestamp(event) do
    case Map.get(event, "timestamp") || Map.get(event, :timestamp) do
      nil -> "—"
      ts when is_binary(ts) -> ts
      %DateTime{} = dt -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> "—"
    end
  end
end
