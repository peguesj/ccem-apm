defmodule ApmV5Web.UsageLive do
  # Author: Jeremiah Pegues <jeremiah@pegues.io>
  @moduledoc """
  LiveView dashboard for Claude model/token usage tracking.

  Displays:
  1. Summary bar — total input/output tokens, top model, effort distribution
  2. Per-model breakdown table — counters per model across all projects
  3. Per-project accordion — model breakdown + effort badge per project

  Subscribes to `"apm:usage"` PubSub and refreshes every 10 seconds.
  """

  use ApmV5Web, :live_view

  alias ApmV5.ClaudeUsageStore

  @refresh_interval 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:usage")
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end

    summary = ClaudeUsageStore.get_summary()
    usage_data = ClaudeUsageStore.get_all_usage()

    socket =
      socket
      |> assign(:page_title, "Claude Usage")
      |> assign(:summary, summary)
      |> assign(:usage_data, usage_data)
      |> assign(:selected_project, nil)

    {:ok, socket}
  end

  @impl true
  def handle_info({:usage_updated, data}, socket) do
    summary = ClaudeUsageStore.get_summary()

    socket =
      socket
      |> assign(:usage_data, data)
      |> assign(:summary, summary)

    {:noreply, socket}
  end

  def handle_info(:refresh, socket) do
    summary = ClaudeUsageStore.get_summary()
    usage_data = ClaudeUsageStore.get_all_usage()

    socket =
      socket
      |> assign(:summary, summary)
      |> assign(:usage_data, usage_data)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_project", %{"project" => project}, socket) do
    selected = if socket.assigns.selected_project == project, do: nil, else: project
    {:noreply, assign(socket, :selected_project, selected)}
  end

  def handle_event("reset_project", %{"project" => project}, socket) do
    ClaudeUsageStore.reset_project(project)
    summary = ClaudeUsageStore.get_summary()
    usage_data = ClaudeUsageStore.get_all_usage()

    socket =
      socket
      |> assign(:summary, summary)
      |> assign(:usage_data, usage_data)
      |> assign(:selected_project, nil)

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <.sidebar_nav current_path="/usage" />

      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Header --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Claude Usage</h2>
            <div class="badge badge-sm badge-ghost">{map_size(@usage_data)} projects</div>
          </div>
          <div class="flex items-center gap-2">
            <span class="text-xs text-base-content/40">Auto-refresh 10s</span>
          </div>
        </header>

        <%!-- Main content --%>
        <main class="flex-1 overflow-y-auto p-4 space-y-4">

          <%!-- Section 1: Summary bar --%>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
            <div class="stat bg-base-200 rounded-lg p-3">
              <div class="stat-title text-xs">Input Tokens</div>
              <div class="stat-value text-lg">{format_tokens(@summary.total_input_tokens)}</div>
            </div>
            <div class="stat bg-base-200 rounded-lg p-3">
              <div class="stat-title text-xs">Output Tokens</div>
              <div class="stat-value text-lg">{format_tokens(@summary.total_output_tokens)}</div>
            </div>
            <div class="stat bg-base-200 rounded-lg p-3">
              <div class="stat-title text-xs">Top Model</div>
              <div class="stat-value text-sm font-mono truncate">{@summary.top_model || "—"}</div>
            </div>
            <div class="stat bg-base-200 rounded-lg p-3">
              <div class="stat-title text-xs">Total Tool Calls</div>
              <div class="stat-value text-lg">{@summary.total_tool_calls}</div>
            </div>
          </div>

          <%!-- Token progress bars --%>
          <%= if @summary.total_input_tokens > 0 || @summary.total_output_tokens > 0 do %>
            <div class="bg-base-200 rounded-lg p-4 space-y-2">
              <h3 class="text-xs font-semibold uppercase tracking-widest text-base-content/50">Token Distribution</h3>
              <div class="space-y-1.5">
                <div class="flex items-center gap-2 text-xs">
                  <span class="w-20 text-base-content/60">Input</span>
                  <div class="flex-1">
                    <progress
                      class="progress progress-info w-full h-2"
                      value={@summary.total_input_tokens}
                      max={max_tokens(@summary)}
                    ></progress>
                  </div>
                  <span class="w-20 text-right font-mono">{format_tokens(@summary.total_input_tokens)}</span>
                </div>
                <div class="flex items-center gap-2 text-xs">
                  <span class="w-20 text-base-content/60">Output</span>
                  <div class="flex-1">
                    <progress
                      class="progress progress-success w-full h-2"
                      value={@summary.total_output_tokens}
                      max={max_tokens(@summary)}
                    ></progress>
                  </div>
                  <span class="w-20 text-right font-mono">{format_tokens(@summary.total_output_tokens)}</span>
                </div>
                <div class="flex items-center gap-2 text-xs">
                  <span class="w-20 text-base-content/60">Cache</span>
                  <div class="flex-1">
                    <progress
                      class="progress progress-warning w-full h-2"
                      value={@summary.total_cache_tokens}
                      max={max_tokens(@summary)}
                    ></progress>
                  </div>
                  <span class="w-20 text-right font-mono">{format_tokens(@summary.total_cache_tokens)}</span>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Section 2: Per-model breakdown table --%>
          <%= if map_size(@summary.model_breakdown) > 0 do %>
            <div class="bg-base-200 rounded-lg overflow-hidden">
              <div class="px-4 py-3 border-b border-base-300">
                <h3 class="text-xs font-semibold uppercase tracking-widest text-base-content/50">Model Breakdown</h3>
              </div>
              <div class="overflow-x-auto">
                <table class="table table-sm w-full">
                  <thead>
                    <tr class="text-base-content/50 text-xs">
                      <th>Model</th>
                      <th class="text-right">Input</th>
                      <th class="text-right">Output</th>
                      <th class="text-right">Cache</th>
                      <th class="text-right">Tool Calls</th>
                      <th class="text-right">Sessions</th>
                      <th>Last Seen</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for {model, stats} <- Enum.sort_by(@summary.model_breakdown, fn {_, s} -> Map.get(s, :input_tokens, 0) end, :desc) do %>
                      <tr class="hover">
                        <td class="font-mono text-xs">{model}</td>
                        <td class="text-right font-mono text-xs">{format_tokens(Map.get(stats, :input_tokens, 0))}</td>
                        <td class="text-right font-mono text-xs">{format_tokens(Map.get(stats, :output_tokens, 0))}</td>
                        <td class="text-right font-mono text-xs">{format_tokens(Map.get(stats, :cache_tokens, 0))}</td>
                        <td class="text-right font-mono text-xs">{Map.get(stats, :tool_calls, 0)}</td>
                        <td class="text-right font-mono text-xs">{Map.get(stats, :sessions, 0)}</td>
                        <td class="text-xs text-base-content/50">{format_last_seen(Map.get(stats, :last_seen))}</td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          <% end %>

          <%!-- Section 3: Per-project accordion --%>
          <%= if map_size(@summary.projects) > 0 do %>
            <div class="space-y-2">
              <h3 class="text-xs font-semibold uppercase tracking-widest text-base-content/50 px-1">Projects</h3>
              <%= for {project, proj_data} <- Enum.sort_by(@summary.projects, fn {p, _} -> p end) do %>
                <div class="bg-base-200 rounded-lg overflow-hidden">
                  <div
                    class="flex items-center justify-between px-4 py-3 cursor-pointer hover:bg-base-300 transition-colors"
                    phx-click="select_project"
                    phx-value-project={project}
                  >
                    <div class="flex items-center gap-3">
                      <span class="font-mono text-sm">{project}</span>
                      <span class={"badge badge-sm #{effort_badge_class(Map.get(proj_data, :effort_level, "low"))}"}>
                        {Map.get(proj_data, :effort_level, "low")}
                      </span>
                    </div>
                    <div class="flex items-center gap-4 text-xs text-base-content/50">
                      <span>{format_tokens(Map.get(proj_data, :input_tokens, 0))} in</span>
                      <span>{format_tokens(Map.get(proj_data, :output_tokens, 0))} out</span>
                      <span>{Map.get(proj_data, :tool_calls, 0)} calls</span>
                      <button
                        class="btn btn-xs btn-ghost text-error"
                        phx-click="reset_project"
                        phx-value-project={project}
                        title="Reset usage counters"
                      >
                        Reset
                      </button>
                    </div>
                  </div>

                  <%= if @selected_project == project do %>
                    <div class="border-t border-base-300 px-4 py-3">
                      <table class="table table-xs w-full">
                        <thead>
                          <tr class="text-base-content/40 text-xs">
                            <th>Model</th>
                            <th class="text-right">Input</th>
                            <th class="text-right">Output</th>
                            <th class="text-right">Cache</th>
                            <th class="text-right">Calls</th>
                            <th class="text-right">Sessions</th>
                            <th>Last Seen</th>
                          </tr>
                        </thead>
                        <tbody>
                          <%= for {model, stats} <- Enum.sort_by(Map.get(proj_data, :model_breakdown, %{}), fn {_, s} -> Map.get(s, :input_tokens, 0) end, :desc) do %>
                            <tr>
                              <td class="font-mono text-xs">{model}</td>
                              <td class="text-right font-mono text-xs">{format_tokens(Map.get(stats, :input_tokens, 0))}</td>
                              <td class="text-right font-mono text-xs">{format_tokens(Map.get(stats, :output_tokens, 0))}</td>
                              <td class="text-right font-mono text-xs">{format_tokens(Map.get(stats, :cache_tokens, 0))}</td>
                              <td class="text-right font-mono text-xs">{Map.get(stats, :tool_calls, 0)}</td>
                              <td class="text-right font-mono text-xs">{Map.get(stats, :sessions, 0)}</td>
                              <td class="text-xs text-base-content/50">{format_last_seen(Map.get(stats, :last_seen))}</td>
                            </tr>
                          <% end %>
                        </tbody>
                      </table>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>

          <%!-- Empty state --%>
          <%= if map_size(@usage_data) == 0 do %>
            <div class="flex flex-col items-center justify-center py-24 text-base-content/30">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-12 w-12 mb-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1" d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z" />
              </svg>
              <p class="text-sm">No usage data recorded yet.</p>
              <p class="text-xs mt-1">The PostToolUse hook will populate this once active.</p>
            </div>
          <% end %>

        </main>
      </div>
    </div>
    """
  end

  # -------------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------------

  defp format_tokens(n) when n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  defp format_tokens(n) when n >= 1_000 do
    "#{Float.round(n / 1_000, 1)}k"
  end

  defp format_tokens(n), do: "#{n}"

  defp format_last_seen(nil), do: "—"

  defp format_last_seen(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)

        cond do
          diff < 60 -> "#{diff}s ago"
          diff < 3600 -> "#{div(diff, 60)}m ago"
          diff < 86400 -> "#{div(diff, 3600)}h ago"
          true -> "#{div(diff, 86400)}d ago"
        end

      _ ->
        iso
    end
  end

  defp max_tokens(%{total_input_tokens: i, total_output_tokens: o, total_cache_tokens: c}) do
    max(i + o + c, 1)
  end

  defp effort_badge_class("intensive"), do: "badge-error"
  defp effort_badge_class("high"), do: "badge-warning"
  defp effort_badge_class("medium"), do: "badge-info"
  defp effort_badge_class(_), do: "badge-ghost"
end
