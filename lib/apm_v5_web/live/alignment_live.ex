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
     |> assign(:error, nil)}
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
    <div class="flex flex-col h-full min-h-screen bg-zinc-950 text-zinc-100">
      <!-- Header -->
      <div class="flex items-center justify-between px-6 py-4 border-b border-zinc-800">
        <div class="flex items-center gap-3">
          <.icon name="hero-magnifying-glass-circle" class="w-6 h-6 text-violet-400" />
          <h1 class="text-lg font-semibold text-zinc-100">Agent Alignment Audit</h1>
          <span class="text-xs text-zinc-500 ml-2">~/.claude/skills/ referential integrity</span>
        </div>
        <div class="flex items-center gap-3">
          <%= if @report do %>
            <span class={[
              "text-sm font-bold px-3 py-1 rounded-full",
              overall_score_class(@report)
            ]}>
              Score: <%= Map.get(@report, "overall_score", 0) %>/100
            </span>
          <% end %>
          <button
            phx-click="run_audit"
            disabled={@running}
            class={[
              "flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium transition-colors",
              if(@running,
                do: "bg-zinc-700 text-zinc-400 cursor-not-allowed",
                else: "bg-violet-600 hover:bg-violet-500 text-white cursor-pointer"
              )
            ]}
          >
            <.icon name={if @running, do: "hero-arrow-path", else: "hero-play"} class={["w-4 h-4", if(@running, do: "animate-spin", else: "")]} />
            <%= if @running, do: "Running Audit...", else: "Run Audit" %>
          </button>
        </div>
      </div>

      <!-- Error banner -->
      <%= if @error do %>
        <div class="mx-6 mt-4 p-3 bg-red-900/30 border border-red-700 rounded-lg text-sm text-red-300">
          <%= @error %>
        </div>
      <% end %>

      <!-- Summary row -->
      <%= if @report do %>
        <div class="flex gap-4 px-6 py-3 border-b border-zinc-800">
          <% summary = Map.get(@report, "summary", %{}) %>
          <div class="flex items-center gap-2 text-sm">
            <span class="w-2 h-2 rounded-full bg-zinc-500"></span>
            <span class="text-zinc-400">Total:</span>
            <span class="text-zinc-100 font-medium"><%= Map.get(summary, "total_skills", 0) %></span>
          </div>
          <div class="flex items-center gap-2 text-sm">
            <span class="w-2 h-2 rounded-full bg-emerald-500"></span>
            <span class="text-zinc-400">Aligned:</span>
            <span class="text-emerald-400 font-medium"><%= Map.get(summary, "fully_aligned", 0) %></span>
          </div>
          <div class="flex items-center gap-2 text-sm">
            <span class="w-2 h-2 rounded-full bg-amber-500"></span>
            <span class="text-zinc-400">Partial:</span>
            <span class="text-amber-400 font-medium"><%= Map.get(summary, "partially_aligned", 0) %></span>
          </div>
          <div class="flex items-center gap-2 text-sm">
            <span class="w-2 h-2 rounded-full bg-red-500"></span>
            <span class="text-zinc-400">Missing:</span>
            <span class="text-red-400 font-medium"><%= Map.get(summary, "missing_alignment", 0) %></span>
          </div>
          <div class="flex items-center gap-2 text-sm ml-auto">
            <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-amber-400" />
            <span class="text-zinc-400">Gaps:</span>
            <span class="text-amber-400 font-medium"><%= Map.get(summary, "gap_count", 0) %></span>
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
          <div class="w-96 border-l border-zinc-800 flex flex-col overflow-hidden">
            <div class="px-4 py-3 border-b border-zinc-800">
              <h2 class="text-sm font-medium text-zinc-300">Alignment Gaps</h2>
              <p class="text-xs text-zinc-500 mt-0.5">
                <%= length(Map.get(@report, "gaps", [])) %> issues requiring attention
              </p>
            </div>
            <div class="flex-1 overflow-y-auto py-2">
              <%= for gap <- Map.get(@report, "gaps", []) do %>
                <% gap = normalize_keys_for_template(gap) %>
                <div class="px-4 py-3 border-b border-zinc-800/60 hover:bg-zinc-900/50">
                  <div class="flex items-start gap-2">
                    <span class={[
                      "mt-0.5 w-2 h-2 rounded-full flex-shrink-0",
                      gap_dot_class(gap["gap_type"])
                    ]}></span>
                    <div class="flex-1 min-w-0">
                      <div class="flex items-center gap-2">
                        <span class="text-xs font-mono text-zinc-300 truncate"><%= gap["skill"] %></span>
                        <span class="text-xs text-zinc-600">·</span>
                        <span class="text-xs text-zinc-500 truncate"><%= format_gap_type(gap["gap_type"]) %></span>
                      </div>
                      <p class="text-xs text-zinc-500 mt-1 leading-relaxed"><%= gap["recommendation"] %></p>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
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
