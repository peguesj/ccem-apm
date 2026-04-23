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
     |> assign(:error, nil
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data())}
  end

  @impl true
  def handle_event("run_audit", _params, socket) do
    case ActionEngine.run_action("agent_alignment_audit", "", %{}) do
      {:ok, run_id} ->
        # Poll for completion
        Process.send_after(self(), {:poll_run, run_id}, 500)
        {:noreply, socket |> assign(:running, true) |> assign(:run_id, run_id) |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, socket |> assign(:error, "Failed to start: #{reason}") |> assign(:running, false)}
    end
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

    # Build skill nodes
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

    # Build gap nodes (one per gap type, linked to skill)
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <.sidebar_nav current_path="/alignment" />

      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0 relative z-10">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Agent Alignment Audit</h2>
            <div class="badge badge-sm badge-ghost">referential integrity</div>
            <%= if @report do %>
              <span class={[
                "text-xs font-bold px-2 py-0.5 rounded-full",
                overall_score_class(@report)
              ]}>
                Score: <%= Map.get(@report, "overall_score", 0) %>/100
              </span>
            <% end %>
          </div>
          <div class="flex items-center gap-2">
            <button
              phx-click="run_audit"
              disabled={@running}
              class={[
                "btn btn-xs gap-1",
                if(@running, do: "btn-disabled", else: "btn-primary")
              ]}
            >
              <.icon name={if @running, do: "hero-arrow-path", else: "hero-play"} class={["size-3.5", if(@running, do: "animate-spin", else: "")]} />
              <%= if @running, do: "Running...", else: "Run Audit" %>
            </button>
          </div>
        </header>

        <!-- Error banner -->
        <%= if @error do %>
          <div class="mx-4 mt-4 p-3 bg-error/10 border border-error/30 rounded-lg text-sm text-error">
            <%= @error %>
          </div>
        <% end %>

        <!-- Summary row -->
        <%= if @report do %>
          <div class="flex gap-4 px-4 py-2 border-b border-base-300 flex-shrink-0 bg-base-200/50">
            <% summary = Map.get(@report, "summary", %{}) %>
            <div class="flex items-center gap-2 text-xs">
              <span class="w-2 h-2 rounded-full bg-base-content/30"></span>
              <span class="text-base-content/60">Total:</span>
              <span class="font-medium"><%= Map.get(summary, "total_skills", 0) %></span>
            </div>
            <div class="flex items-center gap-2 text-xs">
              <span class="w-2 h-2 rounded-full bg-success"></span>
              <span class="text-base-content/60">Aligned:</span>
              <span class="text-success font-medium"><%= Map.get(summary, "fully_aligned", 0) %></span>
            </div>
            <div class="flex items-center gap-2 text-xs">
              <span class="w-2 h-2 rounded-full bg-warning"></span>
              <span class="text-base-content/60">Partial:</span>
              <span class="text-warning font-medium"><%= Map.get(summary, "partially_aligned", 0) %></span>
            </div>
            <div class="flex items-center gap-2 text-xs">
              <span class="w-2 h-2 rounded-full bg-error"></span>
              <span class="text-base-content/60">Missing:</span>
              <span class="text-error font-medium"><%= Map.get(summary, "missing_alignment", 0) %></span>
            </div>
            <div class="flex items-center gap-2 text-xs ml-auto">
              <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-warning" />
              <span class="text-base-content/60">Gaps:</span>
              <span class="text-warning font-medium"><%= Map.get(summary, "gap_count", 0) %></span>
            </div>
          </div>
        <% end %>

        <!-- Main content: graph + gap list -->
        <div class="flex flex-1 overflow-hidden">
          <!-- D3 graph panel -->
          <div class="flex-1 relative overflow-hidden">
          <div
            id="alignment-graph"
            phx-hook="AlignmentGraph"
            class="w-full h-full"
            style="min-height: 600px;"
          >
            <%= if !@report && !@running do %>
              <div class="flex flex-col items-center justify-center h-full gap-4 text-zinc-600">
                <.icon name="hero-magnifying-glass-circle" class="w-16 h-16" />
                <p class="text-sm">Run the audit to visualize agent alignment</p>
              </div>
            <% end %>
            <%= if @running do %>
              <div class="flex flex-col items-center justify-center h-full gap-4 text-violet-400">
                <.icon name="hero-arrow-path" class="w-12 h-12 animate-spin" />
                <p class="text-sm">Scanning skills...</p>
              </div>
            <% end %>
          </div>
        </div>

          <!-- Gaps panel -->
          <%= if @report && length(Map.get(@report, "gaps", [])) > 0 do %>
            <div class="w-96 border-l border-base-300 flex flex-col overflow-hidden">
              <div class="px-4 py-3 border-b border-base-300">
                <h2 class="text-sm font-medium text-base-content">Alignment Gaps</h2>
                <p class="text-xs text-base-content/50 mt-0.5">
                  <%= length(Map.get(@report, "gaps", [])) %> issues requiring attention
                </p>
              </div>
              <div class="flex-1 overflow-y-auto py-2">
                <%= for gap <- Map.get(@report, "gaps", []) do %>
                  <% gap = normalize_keys_for_template(gap) %>
                  <div class="px-4 py-3 border-b border-base-300/60 hover:bg-base-200/50">
                    <div class="flex items-start gap-2">
                      <span class={[
                        "mt-0.5 w-2 h-2 rounded-full flex-shrink-0",
                        gap_dot_class(gap["gap_type"])
                      ]}></span>
                      <div class="flex-1 min-w-0">
                        <div class="flex items-center gap-2">
                          <span class="text-xs font-mono text-base-content truncate"><%= gap["skill"] %></span>
                          <span class="text-xs text-base-content/30">·</span>
                          <span class="text-xs text-base-content/50 truncate"><%= format_gap_type(gap["gap_type"]) %></span>
                        </div>
                        <p class="text-xs text-base-content/50 mt-1 leading-relaxed"><%= gap["recommendation"] %></p>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp overall_score_class(report) do
    score = Map.get(report, "overall_score", 0)
    cond do
      score >= 80 -> "bg-emerald-900/40 text-emerald-400 border border-emerald-700"
      score >= 50 -> "bg-amber-900/40 text-amber-400 border border-amber-700"
      true -> "bg-red-900/40 text-red-400 border border-red-700"
    end
  end

  defp gap_dot_class(gap_type) do
    case gap_type do
      "missing_apm_registration" -> "bg-red-500"
      "missing_formation_role" -> "bg-amber-500"
      "missing_agent_type" -> "bg-amber-500"
      "missing_fmt_convention" -> "bg-zinc-500"
      _ -> "bg-zinc-600"
    end
  end

  defp format_gap_type(nil), do: "unknown"
  defp format_gap_type(t), do: String.replace(t, "_", " ")

  defp normalize_keys_for_template(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
  defp normalize_keys_for_template(other), do: other
end
