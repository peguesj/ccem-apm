defmodule ApmV5Web.AlignmentLive do
  @moduledoc """
  LiveView for the Agent Alignment Audit dashboard at /actions/alignment.

  Displays a D3 force-directed graph of all skills and their agent definitions,
  color-coded by alignment status (green=aligned, amber=partial, red=missing).
  Allows triggering the agent_alignment_audit ActionEngine action and watching
  results animate in real time.
  """

  use ApmV5Web, :live_view

  alias ApmV5.ActionEngine

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "alignment:update")
    end

    {:ok,
     socket
     |> assign(:page_title, "Agent Alignment")
     |> assign(:running, false)
     |> assign(:run_id, nil)
     |> assign(:report, nil)
     |> assign(:error, nil)
     |> assign(:sidebar_collapsed, false)
     |> assign(:inspector_open, false)
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  @impl true
  def handle_event("run_audit", _params, socket) do
    case ActionEngine.run_action("agent_alignment_audit", "", %{}) do
      {:ok, run_id} ->
        Process.send_after(self(), {:poll_run, run_id}, 500)
        {:noreply, socket |> assign(:running, true) |> assign(:run_id, run_id) |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, socket |> assign(:error, "Failed to start: #{reason}") |> assign(:running, false)}
    end
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_collapsed: !socket.assigns.sidebar_collapsed)}
  end

  @impl true
  def handle_info({:poll_run, run_id}, socket) do
    case ActionEngine.get_run(run_id) do
      {:ok, %{status: "completed", result: report}} ->
        socket = socket |> assign(:running, false) |> assign(:report, report)
        {:noreply, push_event(socket, "alignment_data", build_graph_data(report))}

      {:ok, %{status: "failed", error: err}} ->
        {:noreply, socket |> assign(:running, false) |> assign(:error, err)}

      {:ok, %{status: "running"}} ->
        Process.send_after(self(), {:poll_run, run_id}, 800)
        {:noreply, socket}

      _ ->
        {:noreply, socket |> assign(:running, false)}
    end
  end

  def handle_info({:alignment_report, report}, socket) do
    socket = socket |> assign(:report, report) |> assign(:running, false)
    {:noreply, push_event(socket, "alignment_data", build_graph_data(report))}
  end

  defp build_graph_data(nil), do: %{nodes: [], links: []}

  defp build_graph_data(report) do
    skills_with_agents = Map.get(report, "skills_with_agents", []) |> Enum.map(&normalize_keys/1)
    aligned = Map.get(report, "aligned", []) |> Enum.map(&normalize_keys/1)
    partial = Map.get(report, "partial", []) |> Enum.map(&normalize_keys/1)
    gaps = Map.get(report, "gaps", []) |> Enum.map(&normalize_keys/1)

    aligned_names = Enum.map(aligned, & &1["skill"]) |> MapSet.new()
    partial_names = Enum.map(partial, & &1["skill"]) |> MapSet.new()

    skill_nodes =
      Enum.map(skills_with_agents, fn s ->
        name = s["name"] || s["skill"] || "unknown"
        status =
          cond do
            MapSet.member?(aligned_names, name) -> "aligned"
            MapSet.member?(partial_names, name) -> "partial"
            true -> "missing"
          end

        %{
          id: "skill-#{name}",
          label: name,
          type: "skill",
          status: status,
          agent_count: s["agent_count"] || 0,
          integrity_score: s["integrity_score"] || 0
        }
      end)

    gap_nodes =
      gaps
      |> Enum.group_by(& &1["skill"])
      |> Enum.flat_map(fn {skill, skill_gaps} ->
        Enum.with_index(skill_gaps, fn gap, idx ->
          %{
            id: "gap-#{skill}-#{idx}",
            label: String.replace(gap["gap_type"] || "gap", "_", " "),
            type: "gap",
            status: "missing",
            skill: skill,
            recommendation: gap["recommendation"] || ""
          }
        end)
      end)

    gap_links =
      gaps
      |> Enum.group_by(& &1["skill"])
      |> Enum.flat_map(fn {skill, skill_gaps} ->
        Enum.with_index(skill_gaps, fn _gap, idx ->
          %{source: "skill-#{skill}", target: "gap-#{skill}-#{idx}", type: "gap"}
        end)
      end)

    %{
      nodes: skill_nodes ++ gap_nodes,
      links: gap_links,
      summary: Map.get(report, "summary", %{}),
      overall_score: Map.get(report, "overall_score", 0)
    }
  end

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_keys(other), do: other

  defp overall_score_tone(report) do
    score = Map.get(report, "overall_score", 0)
    cond do
      score >= 80 -> "ok"
      score >= 50 -> "warn"
      true -> "err"
    end
  end

  defp gap_dot_tone(gap_type) do
    case gap_type do
      "missing_apm_registration" -> "err"
      "missing_formation_role" -> "warn"
      "missing_agent_type" -> "warn"
      "missing_fmt_convention" -> "neutral"
      _ -> "neutral"
    end
  end

  defp format_gap_type(nil), do: "unknown"
  defp format_gap_type(t), do: String.replace(t, "_", " ")

  defp normalize_keys_for_template(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
  defp normalize_keys_for_template(other), do: other

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar><.sidebar_nav current_path="/actions/alignment" /></:sidebar>
      <:topbar><.top_bar project_name="CCEM APM" /></:topbar>
      <:main>
        <div style="display: flex; flex-direction: column; height: 100%; overflow: hidden;">

          <%!-- Top bar --%>
          <div style="padding: var(--ccem-space-3) var(--ccem-space-4); border-bottom: 1px solid var(--ccem-border); display: flex; align-items: center; justify-content: space-between; flex-shrink: 0; background: var(--ccem-surface-1);">
            <div style="display: flex; align-items: center; gap: var(--ccem-space-3);">
              <h1 style="font-size: var(--ccem-text-sm); font-weight: 600; color: var(--ccem-fg-primary);">
                Agent Alignment Audit
              </h1>
              <.badge tone="neutral">referential integrity</.badge>
              <%= if @report do %>
                <.badge tone={overall_score_tone(@report)}>
                  Score: <%= Map.get(@report, "overall_score", 0) %>/100
                </.badge>
              <% end %>
            </div>
            <.btn
              variant={if @running, do: "secondary", else: "primary"}
              size="xs"
              phx-click="run_audit"
              disabled={@running}
            >
              <.icon
                name={if @running, do: "hero-arrow-path", else: "hero-play"}
                class={["size-3", if(@running, do: "animate-spin", else: "")]}
              />
              <%= if @running, do: "Running…", else: "Run Audit" %>
            </.btn>
          </div>

          <%!-- Error banner --%>
          <%= if @error do %>
            <div style="margin: var(--ccem-space-4); padding: var(--ccem-space-3); background: color-mix(in srgb, var(--ccem-err) 10%, transparent); border: 1px solid color-mix(in srgb, var(--ccem-err) 30%, transparent); border-radius: var(--ccem-radius); font-size: var(--ccem-text-sm); color: var(--ccem-err);">
              <%= @error %>
            </div>
          <% end %>

          <%!-- Summary strip --%>
          <%= if @report do %>
            <% summary = Map.get(@report, "summary", %{}) %>
            <div style="display: flex; align-items: center; gap: var(--ccem-space-4); padding: var(--ccem-space-2) var(--ccem-space-4); border-bottom: 1px solid var(--ccem-border); flex-shrink: 0; background: var(--ccem-surface-2);">
              <div style="display: flex; align-items: center; gap: var(--ccem-space-2);">
                <.badge tone="neutral" dot={true} square={true}> </.badge>
                <span style="font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted);">Total:</span>
                <span style="font-size: var(--ccem-text-xs); font-weight: 500; color: var(--ccem-fg-secondary);">
                  <%= Map.get(summary, "total_skills", 0) %>
                </span>
              </div>
              <div style="display: flex; align-items: center; gap: var(--ccem-space-2);">
                <.badge tone="ok" dot={true} square={true}> </.badge>
                <span style="font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted);">Aligned:</span>
                <span style="font-size: var(--ccem-text-xs); font-weight: 500; color: var(--ccem-ok);">
                  <%= Map.get(summary, "fully_aligned", 0) %>
                </span>
              </div>
              <div style="display: flex; align-items: center; gap: var(--ccem-space-2);">
                <.badge tone="warn" dot={true} square={true}> </.badge>
                <span style="font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted);">Partial:</span>
                <span style="font-size: var(--ccem-text-xs); font-weight: 500; color: var(--ccem-warn);">
                  <%= Map.get(summary, "partially_aligned", 0) %>
                </span>
              </div>
              <div style="display: flex; align-items: center; gap: var(--ccem-space-2);">
                <.badge tone="err" dot={true} square={true}> </.badge>
                <span style="font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted);">Missing:</span>
                <span style="font-size: var(--ccem-text-xs); font-weight: 500; color: var(--ccem-err);">
                  <%= Map.get(summary, "missing_alignment", 0) %>
                </span>
              </div>
              <div style="display: flex; align-items: center; gap: var(--ccem-space-2); margin-left: auto;">
                <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-warn" />
                <span style="font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted);">Gaps:</span>
                <span style="font-size: var(--ccem-text-xs); font-weight: 500; color: var(--ccem-warn);">
                  <%= Map.get(summary, "gap_count", 0) %>
                </span>
              </div>
            </div>
          <% end %>

          <%!-- Main panel: graph + gaps --%>
          <div style="display: flex; flex: 1; overflow: hidden;">

            <%!-- D3 graph panel --%>
            <div style="flex: 1; position: relative; overflow: hidden;">
              <div
                id="alignment-graph"
                phx-hook="AlignmentGraph"
                style="width: 100%; height: 100%; min-height: 600px;"
              >
                <%= if !@report && !@running do %>
                  <div style="display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100%; gap: var(--ccem-space-4); color: var(--ccem-fg-muted);">
                    <.icon name="hero-magnifying-glass-circle" class="w-16 h-16 opacity-40" />
                    <p style="font-size: var(--ccem-text-sm);">Run the audit to visualize agent alignment</p>
                  </div>
                <% end %>
                <%= if @running do %>
                  <div style="display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100%; gap: var(--ccem-space-4); color: var(--ccem-accent);">
                    <.icon name="hero-arrow-path" class="w-12 h-12 animate-spin" />
                    <p style="font-size: var(--ccem-text-sm);">Scanning skills…</p>
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Gaps side panel --%>
            <%= if @report && length(Map.get(@report, "gaps", [])) > 0 do %>
              <div style="width: 24rem; border-left: 1px solid var(--ccem-border); display: flex; flex-direction: column; overflow: hidden;">
                <div style="padding: var(--ccem-space-3) var(--ccem-space-4); border-bottom: 1px solid var(--ccem-border);">
                  <h2 style="font-size: var(--ccem-text-sm); font-weight: 500; color: var(--ccem-fg-primary);">Alignment Gaps</h2>
                  <p style="font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted); margin-top: 2px;">
                    <%= length(Map.get(@report, "gaps", [])) %> issues requiring attention
                  </p>
                </div>
                <div style="flex: 1; overflow-y: auto; padding: var(--ccem-space-2) 0;">
                  <%= for gap <- Map.get(@report, "gaps", []) do %>
                    <% gap = normalize_keys_for_template(gap) %>
                    <div style="padding: var(--ccem-space-3) var(--ccem-space-4); border-bottom: 1px solid color-mix(in srgb, var(--ccem-border) 60%, transparent);">
                      <div style="display: flex; align-items: flex-start; gap: var(--ccem-space-2);">
                        <.badge tone={gap_dot_tone(gap["gap_type"])} dot={true} square={true}> </.badge>
                        <div style="flex: 1; min-width: 0;">
                          <div style="display: flex; align-items: center; gap: var(--ccem-space-2);">
                            <span style="font-family: var(--ccem-font-mono); font-size: var(--ccem-text-xs); color: var(--ccem-fg-primary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                              <%= gap["skill"] %>
                            </span>
                            <span style="color: var(--ccem-fg-muted);">·</span>
                            <span style="font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                              <%= format_gap_type(gap["gap_type"]) %>
                            </span>
                          </div>
                          <p style="font-size: var(--ccem-text-xs); color: var(--ccem-fg-muted); margin-top: 4px; line-height: 1.5;">
                            <%= gap["recommendation"] %>
                          </p>
                        </div>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>

          </div>
        </div>
      </:main>
      <:inspector></:inspector>
    </.page_layout>
    """
  end
end
