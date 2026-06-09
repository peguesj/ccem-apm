defmodule ApmWeb.UsageLive do
  # Author: Jeremiah Pegues <jeremiah@pegues.io>
  @moduledoc """
  LiveView dashboard for Claude model/token usage tracking.

  Displays:
  1. Summary bar — total input/output tokens, top model, effort distribution
  2. Per-model breakdown table — counters per model across all projects
  3. Per-project accordion — model breakdown + effort badge per project
     - Each project row has an expandable token breakdown stacked bar graph
       showing input (blue/info), output (green/success), and cache (amber/warning)
       proportions side-by-side with a labelled legend.

  Subscribes to `"apm:usage"` PubSub and refreshes every 10 seconds.
  """

  use ApmWeb, :live_view

  alias Apm.ClaudeUsageStore

  @refresh_interval 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:usage")
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
      |> assign(:expanded_projects, MapSet.new())
      |> assign(:sidebar_collapsed, false)
      |> assign(:inspector_open, false)

    {:ok, socket |> ApmWeb.Components.SidebarNav.assign_sidebar_nav_data()}
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

  # Broadcast from ClaudeUsageStore when a new usage event is recorded.
  # Refresh both summary and raw usage data.
  def handle_info({:usage_recorded, _event}, socket) do
    summary = ClaudeUsageStore.get_summary()
    usage_data = ClaudeUsageStore.get_all_usage()

    socket =
      socket
      |> assign(:summary, summary)
      |> assign(:usage_data, usage_data)

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

  def handle_event("toggle_project_expand", %{"project" => proj}, socket) do
    expanded = socket.assigns.expanded_projects

    new_expanded =
      if MapSet.member?(expanded, proj),
        do: MapSet.delete(expanded, proj),
        else: MapSet.put(expanded, proj)

    {:noreply, assign(socket, :expanded_projects, new_expanded)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar><.sidebar_nav current_path="/usage" /></:sidebar>
      <:topbar><.top_bar project_name="CCEM APM" /></:topbar>
      <:main>
        <%!-- Page header --%>
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
          <div style="display: flex; align-items: center; gap: 10px;">
            <h1 style="margin: 0; font-size: 16px; font-weight: 600; color: var(--ccem-fg);">
              Claude Usage
            </h1>
            <.badge tone="neutral">{map_size(@usage_data)} projects</.badge>
          </div>
          <span style="font-size: var(--ccem-t-sm, 13px); color: var(--ccem-fg-dim);">
            Auto-refresh 10s
          </span>
        </div>

        <%!-- Section 1: Summary stat tiles --%>
        <div style="display: flex; gap: 12px; margin-bottom: 16px; flex-wrap: wrap;">
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Input Tokens" value={format_tokens(@summary.total_input_tokens)} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Output Tokens" value={format_tokens(@summary.total_output_tokens)} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Top Model" value={@summary.top_model || "—"} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Total Tool Calls" value={to_string(@summary.total_tool_calls)} />
          </.card>
        </div>

        <%!-- Token Distribution progress bars --%>
        <%= if @summary.total_input_tokens > 0 || @summary.total_output_tokens > 0 do %>
          <.card style="margin-bottom: 16px; padding: 16px;">
            <div style="font-size: var(--ccem-t-sm, 13px); font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--ccem-fg-dim); margin-bottom: 10px;">
              Token Distribution
            </div>
            <div style="display: flex; flex-direction: column; gap: 8px;">
              <div style="display: flex; align-items: center; gap: 10px; font-size: var(--ccem-t-sm, 13px);">
                <span style="width: 56px; color: var(--ccem-fg-dim);">Input</span>
                <div style="flex: 1;">
                  <progress
                    style="width: 100%; height: 6px; accent-color: var(--ccem-info, #60a5fa);"
                    value={@summary.total_input_tokens}
                    max={max_tokens(@summary)}
                  >
                  </progress>
                </div>
                <span style="width: 72px; text-align: right; font-family: monospace; color: var(--ccem-fg);">
                  {format_tokens(@summary.total_input_tokens)}
                </span>
              </div>
              <div style="display: flex; align-items: center; gap: 10px; font-size: var(--ccem-t-sm, 13px);">
                <span style="width: 56px; color: var(--ccem-fg-dim);">Output</span>
                <div style="flex: 1;">
                  <progress
                    style="width: 100%; height: 6px; accent-color: var(--ccem-ok, #4ade80);"
                    value={@summary.total_output_tokens}
                    max={max_tokens(@summary)}
                  >
                  </progress>
                </div>
                <span style="width: 72px; text-align: right; font-family: monospace; color: var(--ccem-fg);">
                  {format_tokens(@summary.total_output_tokens)}
                </span>
              </div>
              <div style="display: flex; align-items: center; gap: 10px; font-size: var(--ccem-t-sm, 13px);">
                <span style="width: 56px; color: var(--ccem-fg-dim);">Cache</span>
                <div style="flex: 1;">
                  <progress
                    style="width: 100%; height: 6px; accent-color: var(--ccem-warn, #fbbf24);"
                    value={@summary.total_cache_tokens}
                    max={max_tokens(@summary)}
                  >
                  </progress>
                </div>
                <span style="width: 72px; text-align: right; font-family: monospace; color: var(--ccem-fg);">
                  {format_tokens(@summary.total_cache_tokens)}
                </span>
              </div>
            </div>
          </.card>
        <% end %>

        <%!-- Section 2: Per-model breakdown table --%>
        <% nonzero_models = nonzero_model_breakdown(@summary.model_breakdown) %>
        <%= cond do %>
          <% map_size(@summary.model_breakdown) == 0 -> %>
            <.card style="margin-bottom: 16px; padding: 32px; text-align: center;">
              <p style="font-size: var(--ccem-t-sm, 13px); color: var(--ccem-fg-dim); margin: 0 0 4px;">
                No usage recorded yet
              </p>
              <p style="font-size: var(--ccem-t-sm, 13px); color: var(--ccem-fg-dim); margin: 0; opacity: 0.6;">
                Claude tool invocations write usage events to <code>~/.claude/projects/*/</code>.
                Use Claude Code with any model and reload this page.
              </p>
            </.card>
          <% nonzero_models == [] -> %>
            <.card style="margin-bottom: 16px; padding: 32px; text-align: center;">
              <p style="font-size: var(--ccem-t-sm, 13px); color: var(--ccem-fg-dim); margin: 0 0 4px;">
                Model metadata present but all token counts are zero
              </p>
              <p style="font-size: var(--ccem-t-sm, 13px); color: var(--ccem-fg-dim); margin: 0; opacity: 0.6;">
                Usage events may have been reset. New invocations will populate this table.
              </p>
            </.card>
          <% true -> %>
            <div style="margin-bottom: 6px; font-size: var(--ccem-t-sm, 13px); font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--ccem-fg-dim);">
              Model Breakdown
            </div>
            <.card padded={false} style="margin-bottom: 16px;">
              <.data_table
                id="usage-model-table"
                rows={
                  Enum.sort_by(nonzero_models, fn {_, s} -> Map.get(s, :input_tokens, 0) end, :desc)
                }
              >
                <:col :let={{model, _stats}} label="Model">
                  <span style="font-family: monospace; font-size: var(--ccem-t-sm, 13px);">
                    {model}
                  </span>
                </:col>
                <:col :let={{_model, stats}} label="Input">
                  <span style="font-family: monospace; font-size: var(--ccem-t-sm, 13px);">
                    {format_tokens(Map.get(stats, :input_tokens, 0))}
                  </span>
                </:col>
                <:col :let={{_model, stats}} label="Output">
                  <span style="font-family: monospace; font-size: var(--ccem-t-sm, 13px);">
                    {format_tokens(Map.get(stats, :output_tokens, 0))}
                  </span>
                </:col>
                <:col :let={{_model, stats}} label="Cache">
                  <span style="font-family: monospace; font-size: var(--ccem-t-sm, 13px);">
                    {format_tokens(Map.get(stats, :cache_tokens, 0))}
                  </span>
                </:col>
                <:col :let={{_model, stats}} label="Tool Calls">
                  {Map.get(stats, :tool_calls, 0)}
                </:col>
                <:col :let={{_model, stats}} label="Sessions">
                  {Map.get(stats, :sessions, 0)}
                </:col>
                <:col :let={{_model, stats}} label="Last Seen">
                  <span style="color: var(--ccem-fg-dim);">
                    {format_last_seen(Map.get(stats, :last_seen))}
                  </span>
                </:col>
              </.data_table>
            </.card>
        <% end %>

        <%!-- Section 3: Per-project accordion --%>
        <%= if map_size(@summary.projects) > 0 do %>
          <div style="margin-bottom: 6px; font-size: var(--ccem-t-sm, 13px); font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--ccem-fg-dim);">
            Projects
          </div>
          <div style="display: flex; flex-direction: column; gap: 8px; margin-bottom: 16px;">
            <%= for {project, proj_data} <- Enum.sort_by(@summary.projects, fn {p, _} -> p end) do %>
              <% breakdown = token_breakdown(proj_data) %>
              <.card padded={false}>
                <%!-- Project header row --%>
                <div
                  style="display: flex; align-items: center; justify-content: space-between; padding: 10px 16px; cursor: pointer;"
                  phx-click="select_project"
                  phx-value-project={project}
                >
                  <div style="display: flex; align-items: center; gap: 10px;">
                    <button
                      style="background: none; border: none; cursor: pointer; padding: 0; color: var(--ccem-fg-dim); display: flex; align-items: center;"
                      phx-click="toggle_project_expand"
                      phx-value-project={project}
                      title={
                        if MapSet.member?(@expanded_projects, project),
                          do: "Collapse token graph",
                          else: "Expand token graph"
                      }
                    >
                      <%= if MapSet.member?(@expanded_projects, project) do %>
                        <svg
                          xmlns="http://www.w3.org/2000/svg"
                          style="width: 12px; height: 12px;"
                          fill="none"
                          viewBox="0 0 24 24"
                          stroke="currentColor"
                        >
                          <path
                            stroke-linecap="round"
                            stroke-linejoin="round"
                            stroke-width="2"
                            d="M19 9l-7 7-7-7"
                          />
                        </svg>
                      <% else %>
                        <svg
                          xmlns="http://www.w3.org/2000/svg"
                          style="width: 12px; height: 12px;"
                          fill="none"
                          viewBox="0 0 24 24"
                          stroke="currentColor"
                        >
                          <path
                            stroke-linecap="round"
                            stroke-linejoin="round"
                            stroke-width="2"
                            d="M9 5l7 7-7 7"
                          />
                        </svg>
                      <% end %>
                    </button>
                    <span style="font-family: monospace; font-size: var(--ccem-t-sm, 13px); color: var(--ccem-fg);">
                      {project}
                    </span>
                    <.badge tone={effort_tone(Map.get(proj_data, :effort_level, "low"))}>
                      {Map.get(proj_data, :effort_level, "low")}
                    </.badge>
                  </div>
                  <div style="display: flex; align-items: center; gap: 16px;">
                    <span style="font-size: var(--ccem-t-sm, 13px); color: var(--ccem-fg-dim);">
                      {format_tokens(Map.get(proj_data, :input_tokens, 0))} in
                    </span>
                    <span style="font-size: var(--ccem-t-sm, 13px); color: var(--ccem-fg-dim);">
                      {format_tokens(Map.get(proj_data, :output_tokens, 0))} out
                    </span>
                    <span style="font-size: var(--ccem-t-sm, 13px); color: var(--ccem-fg-dim);">
                      {Map.get(proj_data, :tool_calls, 0)} calls
                    </span>
                    <.btn
                      variant="ghost"
                      size="xs"
                      phx-click="reset_project"
                      phx-value-project={project}
                    >
                      Reset
                    </.btn>
                  </div>
                </div>

                <%!-- Expandable token breakdown stacked bar --%>
                <%= if MapSet.member?(@expanded_projects, project) do %>
                  <div style="border-top: 1px solid var(--ccem-border, rgba(255,255,255,0.08)); padding: 12px 16px;">
                    <div style="font-size: var(--ccem-t-sm, 13px); font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--ccem-fg-dim); margin-bottom: 8px;">
                      Token Breakdown
                    </div>
                    <div style="display: flex; height: 14px; border-radius: 4px; overflow: hidden; width: 100%; margin-bottom: 8px;">
                      <%= if breakdown.input_pct > 0 do %>
                        <div
                          style={"width: #{breakdown.input_pct}%; background: var(--ccem-info, #60a5fa); opacity: 0.7; transition: width 0.3s;"}
                          title={"Input: #{format_tokens(breakdown.input)}"}
                        >
                        </div>
                      <% end %>
                      <%= if breakdown.output_pct > 0 do %>
                        <div
                          style={"width: #{breakdown.output_pct}%; background: var(--ccem-ok, #4ade80); opacity: 0.7; transition: width 0.3s;"}
                          title={"Output: #{format_tokens(breakdown.output)}"}
                        >
                        </div>
                      <% end %>
                      <%= if breakdown.cache_pct > 0 do %>
                        <div
                          style={"width: #{breakdown.cache_pct}%; background: var(--ccem-warn, #fbbf24); opacity: 0.7; transition: width 0.3s;"}
                          title={"Cache: #{format_tokens(breakdown.cache)}"}
                        >
                        </div>
                      <% end %>
                    </div>
                    <div style="display: flex; flex-wrap: wrap; gap: 12px; font-size: var(--ccem-t-sm, 13px); color: var(--ccem-fg-dim);">
                      <div style="display: flex; align-items: center; gap: 6px;">
                        <div style="width: 10px; height: 10px; border-radius: 2px; background: var(--ccem-info, #60a5fa); opacity: 0.7; flex-shrink: 0;">
                        </div>
                        <span>
                          Input
                          <span style="font-family: monospace; color: var(--ccem-fg);">
                            {format_tokens(breakdown.input)}
                          </span>
                          ({breakdown.input_pct}%)
                        </span>
                      </div>
                      <div style="display: flex; align-items: center; gap: 6px;">
                        <div style="width: 10px; height: 10px; border-radius: 2px; background: var(--ccem-ok, #4ade80); opacity: 0.7; flex-shrink: 0;">
                        </div>
                        <span>
                          Output
                          <span style="font-family: monospace; color: var(--ccem-fg);">
                            {format_tokens(breakdown.output)}
                          </span>
                          ({breakdown.output_pct}%)
                        </span>
                      </div>
                      <%= if breakdown.cache > 0 do %>
                        <div style="display: flex; align-items: center; gap: 6px;">
                          <div style="width: 10px; height: 10px; border-radius: 2px; background: var(--ccem-warn, #fbbf24); opacity: 0.7; flex-shrink: 0;">
                          </div>
                          <span>
                            Cache
                            <span style="font-family: monospace; color: var(--ccem-fg);">
                              {format_tokens(breakdown.cache)}
                            </span>
                            ({breakdown.cache_pct}%)
                          </span>
                        </div>
                      <% end %>
                      <div style="display: flex; align-items: center; gap: 6px; margin-left: auto;">
                        <span style="color: var(--ccem-fg-dim);">Total:</span>
                        <span style="font-family: monospace; color: var(--ccem-fg);">
                          {format_tokens(breakdown.total)}
                        </span>
                      </div>
                    </div>
                  </div>
                <% end %>

                <%!-- Per-project model breakdown (selected) --%>
                <%= if @selected_project == project do %>
                  <div style="border-top: 1px solid var(--ccem-border, rgba(255,255,255,0.08));">
                    <.data_table
                      id={"usage-proj-#{project}-table"}
                      rows={
                        Enum.sort_by(
                          Map.get(proj_data, :model_breakdown, %{}),
                          fn {_, s} -> Map.get(s, :input_tokens, 0) end,
                          :desc
                        )
                      }
                    >
                      <:col :let={row} label="Model">
                        <span style="font-family: monospace; font-size: var(--ccem-t-sm, 13px);">
                          {elem(row, 0)}
                        </span>
                      </:col>
                      <:col :let={row} label="Input">
                        <span style="font-family: monospace; font-size: var(--ccem-t-sm, 13px);">
                          {format_tokens(Map.get(elem(row, 1), :input_tokens, 0))}
                        </span>
                      </:col>
                      <:col :let={row} label="Output">
                        <span style="font-family: monospace; font-size: var(--ccem-t-sm, 13px);">
                          {format_tokens(Map.get(elem(row, 1), :output_tokens, 0))}
                        </span>
                      </:col>
                      <:col :let={row} label="Cache">
                        <span style="font-family: monospace; font-size: var(--ccem-t-sm, 13px);">
                          {format_tokens(Map.get(elem(row, 1), :cache_tokens, 0))}
                        </span>
                      </:col>
                      <:col :let={row} label="Calls">
                        {Map.get(elem(row, 1), :tool_calls, 0)}
                      </:col>
                      <:col :let={row} label="Sessions">
                        {Map.get(elem(row, 1), :sessions, 0)}
                      </:col>
                      <:col :let={row} label="Last Seen">
                        <span style="color: var(--ccem-fg-dim);">
                          {format_last_seen(Map.get(elem(row, 1), :last_seen))}
                        </span>
                      </:col>
                    </.data_table>
                  </div>
                <% end %>
              </.card>
            <% end %>
          </div>
        <% end %>

        <%!-- Empty state --%>
        <%= if map_size(@usage_data) == 0 do %>
          <div style="display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 80px 24px; color: var(--ccem-fg-dim);">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              style="width: 40px; height: 40px; margin-bottom: 12px; opacity: 0.3;"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="1"
                d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"
              />
            </svg>
            <p style="font-size: var(--ccem-t-sm, 13px); margin: 0 0 4px;">
              No usage data recorded yet.
            </p>
            <p style="font-size: var(--ccem-t-sm, 13px); margin: 0; opacity: 0.6;">
              The PostToolUse hook will populate this once active.
            </p>
          </div>
        <% end %>
      </:main>
    </.page_layout>
    """
  end

  # -------------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------------

  defp nonzero_model_breakdown(breakdown) do
    Enum.filter(breakdown, fn {_model, stats} ->
      Map.get(stats, :input_tokens, 0) > 0 ||
        Map.get(stats, :output_tokens, 0) > 0 ||
        Map.get(stats, :cache_tokens, 0) > 0 ||
        Map.get(stats, :tool_calls, 0) > 0
    end)
  end

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

  defp effort_tone("intensive"), do: "error"
  defp effort_tone("high"), do: "warning"
  defp effort_tone("medium"), do: "info"
  defp effort_tone(_), do: "neutral"

  @doc false
  @spec token_breakdown(map()) :: %{
          input: integer(),
          input_pct: integer(),
          output: integer(),
          output_pct: integer(),
          cache: integer(),
          cache_pct: integer(),
          total: integer()
        }
  defp token_breakdown(usage_data) do
    input = Map.get(usage_data, :input_tokens, 0) |> to_int()
    output = Map.get(usage_data, :output_tokens, 0) |> to_int()
    cache = Map.get(usage_data, :cache_tokens, 0) |> to_int()
    total = max(input + output + cache, 1)

    %{
      input: input,
      input_pct: round(input / total * 100),
      output: output,
      output_pct: round(output / total * 100),
      cache: cache,
      cache_pct: round(cache / total * 100),
      total: total
    }
  end

  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_float(v), do: round(v)
  defp to_int(_), do: 0
end
