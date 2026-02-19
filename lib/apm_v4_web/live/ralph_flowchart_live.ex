defmodule ApmV4Web.RalphFlowchartLive do
  @moduledoc """
  LiveView page rendering the Ralph methodology flowchart using D3.js.

  Ported from the React/xyflow implementation at ~/Developer/ralph/flowchart/
  to Phoenix LiveView with a D3.js JS hook. Displays 10 Ralph methodology steps
  in 4 phases (setup, loop, decision, done) with animated edges and step
  progression controls.
  """

  use ApmV4Web, :live_view

  alias ApmV4.ConfigLoader
  alias ApmV4.Ralph

  @default_steps [
    %{id: "1", label: "You write a PRD", description: "Define what you want to build", phase: "setup"},
    %{id: "2", label: "Convert to prd.json", description: "Break into small user stories", phase: "setup"},
    %{id: "3", label: "Run ralph.sh", description: "Starts the autonomous loop", phase: "setup"},
    %{id: "4", label: "AI picks a story", description: "Finds next passes: false", phase: "loop"},
    %{id: "5", label: "Implements it", description: "Writes code, runs tests", phase: "loop"},
    %{id: "6", label: "Commits changes", description: "If tests pass", phase: "loop"},
    %{id: "7", label: "Updates prd.json", description: "Sets passes: true", phase: "loop"},
    %{id: "8", label: "Logs to progress.txt", description: "Saves learnings", phase: "loop"},
    %{id: "9", label: "More stories?", description: "Decision node", phase: "decision"},
    %{id: "10", label: "Done!", description: "All stories complete", phase: "done"}
  ]

  @default_edges [
    %{source: "1", target: "2"},
    %{source: "2", target: "3"},
    %{source: "3", target: "4"},
    %{source: "4", target: "5"},
    %{source: "5", target: "6"},
    %{source: "6", target: "7"},
    %{source: "7", target: "8"},
    %{source: "8", target: "9"},
    %{source: "9", target: "4", label: "Yes"},
    %{source: "9", target: "10", label: "No"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:config")
    end

    {steps, edges, ralph_data} = load_ralph_data()

    socket =
      socket
      |> assign(:page_title, "Ralph Flowchart")
      |> assign(:steps, steps)
      |> assign(:edges, edges)
      |> assign(:ralph_data, ralph_data)
      |> assign(:visible_count, length(steps))
      |> assign(:active_skill_count, skill_count())
      |> assign(:active_step, nil)
      |> assign(:selected_step, nil)
      |> push_flowchart_data(steps, edges, length(steps))

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <%!-- Sidebar --%>
      <aside class="w-56 bg-base-200 border-r border-base-300 flex flex-col flex-shrink-0">
        <div class="p-4 border-b border-base-300">
          <h1 class="text-lg font-bold text-primary flex items-center gap-2">
            <span class="inline-block w-2 h-2 rounded-full bg-success animate-pulse"></span>
            CCEM APM v4
          </h1>
          <p class="text-xs text-base-content/50 mt-1">Agent Performance Monitor</p>
        </div>
        <nav class="flex-1 p-2 space-y-1">
          <.nav_item icon="hero-squares-2x2" label="Dashboard" active={false} href="/" />
          <.nav_item icon="hero-globe-alt" label="All Projects" active={false} href="/apm-all" />
          <.nav_item icon="hero-sparkles" label="Skills" active={false} href="/skills" badge={@active_skill_count} />
          <.nav_item icon="hero-arrow-path" label="Ralph" active={true} href="/ralph" />
          <.nav_item icon="hero-clock" label="Timeline" active={false} href="/timeline" />
          <.nav_item icon="hero-rectangle-group" label="Formations" active={false} href="/formation" />
          <.nav_item icon="hero-signal" label="Ports" active={false} href="/ports" />
          <.nav_item icon="hero-book-open" label="Docs" active={false} href="/docs" />
        </nav>
      </aside>

      <%!-- Main content --%>
      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Top bar --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Ralph Methodology</h2>
            <div class="badge badge-sm badge-ghost">
              Step {@visible_count} of {length(@steps)}
            </div>
          </div>
          <div class="flex items-center gap-2">
            <button
              class="btn btn-ghost btn-xs"
              phx-click="reset_steps"
              disabled={@visible_count == 1}
            >
              Reset
            </button>
            <button
              class="btn btn-ghost btn-xs"
              phx-click="prev_step"
              disabled={@visible_count <= 1}
            >
              Previous
            </button>
            <button
              class="btn btn-primary btn-xs"
              phx-click="next_step"
              disabled={@visible_count >= length(@steps)}
            >
              Next
            </button>
          </div>
        </header>

        <%!-- Flowchart body --%>
        <div class="flex-1 flex overflow-hidden">
          <%!-- Flowchart area --%>
          <div class="flex-1 overflow-hidden relative">
            <div
              id="ralph-flowchart"
              class="w-full h-full"
              phx-hook="RalphFlowchart"
              phx-update="ignore"
            >
            </div>
          </div>

          <%!-- Step details panel --%>
          <div class="w-72 border-l border-base-300 bg-base-200 flex flex-col flex-shrink-0 overflow-y-auto">
            <div class="p-4 border-b border-base-300">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                Step Details
              </h3>
            </div>
            <div class="p-4">
              <div :if={@selected_step == nil} class="text-center text-base-content/30 py-8 text-xs">
                Click a node to view step details
              </div>
              <div :if={@selected_step} class="space-y-4">
                <div>
                  <div class={["inline-block px-2 py-0.5 rounded text-xs font-semibold mb-2", phase_badge_class(@selected_step.phase)]}>
                    {@selected_step.phase}
                  </div>
                  <h3 class="text-lg font-bold">{@selected_step.label}</h3>
                  <p class="text-sm text-base-content/60 mt-1">{@selected_step.description}</p>
                </div>
                <div class="text-xs text-base-content/40">
                  Step {@selected_step.id} of {length(@steps)}
                </div>
              </div>
            </div>

            <%!-- Steps list --%>
            <div class="p-4 border-t border-base-300">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3">
                All Steps
              </h3>
              <div class="space-y-1">
                <button
                  :for={step <- @steps}
                  class={[
                    "w-full text-left px-3 py-2 rounded text-xs transition-colors",
                    step_visible?(step, @visible_count) && "opacity-100",
                    !step_visible?(step, @visible_count) && "opacity-30",
                    @selected_step && @selected_step.id == step.id && "bg-primary/10 text-primary",
                    !(@selected_step && @selected_step.id == step.id) && "hover:bg-base-300"
                  ]}
                  phx-click="select_step"
                  phx-value-step-id={step.id}
                >
                  <div class="flex items-center gap-2">
                    <span class={["inline-block w-2 h-2 rounded-full", phase_dot_class(step.phase)]}></span>
                    <span class="font-medium">{step.label}</span>
                  </div>
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("next_step", _params, socket) do
    steps = socket.assigns.steps
    edges = socket.assigns.edges
    new_count = min(socket.assigns.visible_count + 1, length(steps))

    socket =
      socket
      |> assign(:visible_count, new_count)
      |> push_flowchart_data(steps, edges, new_count)

    {:noreply, socket}
  end

  def handle_event("prev_step", _params, socket) do
    steps = socket.assigns.steps
    edges = socket.assigns.edges
    new_count = max(socket.assigns.visible_count - 1, 1)

    socket =
      socket
      |> assign(:visible_count, new_count)
      |> push_flowchart_data(steps, edges, new_count)

    {:noreply, socket}
  end

  def handle_event("reset_steps", _params, socket) do
    steps = socket.assigns.steps
    edges = socket.assigns.edges

    socket =
      socket
      |> assign(:visible_count, 1)
      |> push_flowchart_data(steps, edges, 1)

    {:noreply, socket}
  end

  def handle_event("advance_step", _params, socket) do
    steps = socket.assigns.steps
    edges = socket.assigns.edges
    new_count = min(socket.assigns.visible_count + 1, length(steps))

    socket =
      socket
      |> assign(:visible_count, new_count)
      |> push_flowchart_data(steps, edges, new_count)

    {:noreply, socket}
  end

  def handle_event("jump_to_step", %{"step" => step_str}, socket) do
    steps = socket.assigns.steps
    edges = socket.assigns.edges
    step_num = String.to_integer(step_str)
    new_count = max(1, min(step_num, length(steps)))

    socket =
      socket
      |> assign(:visible_count, new_count)
      |> push_flowchart_data(steps, edges, new_count)

    {:noreply, socket}
  end

  def handle_event("select_step", %{"step-id" => step_id}, socket) do
    selected = Enum.find(socket.assigns.steps, fn s -> s.id == step_id end)
    {:noreply, assign(socket, :selected_step, selected)}
  end

  @impl true
  def handle_info({:config_reloaded, _config}, socket) do
    {steps, edges, ralph_data} = load_ralph_data()

    socket =
      socket
      |> assign(:steps, steps)
      |> assign(:edges, edges)
      |> assign(:ralph_data, ralph_data)
      |> assign(:visible_count, length(steps))
      |> push_flowchart_data(steps, edges, length(steps))

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Helper Components ---

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :href, :string, required: true
  attr :badge, :any, default: nil

  defp nav_item(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "flex items-center gap-3 px-3 py-2 rounded text-sm transition-colors",
        @active && "bg-primary/10 text-primary font-medium",
        !@active && "text-base-content/60 hover:text-base-content hover:bg-base-300"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
      <span :if={@badge && @badge > 0} class="badge badge-xs badge-primary ml-auto">{@badge}</span>
    </a>
    """
  end

  defp skill_count do
    try do
      map_size(ApmV4.SkillTracker.get_skill_catalog())
    catch
      :exit, _ -> 0
    end
  end

  # --- Private Helpers ---

  defp push_flowchart_data(socket, steps, edges, visible_count) do
    visible_ids =
      steps
      |> Enum.take(visible_count)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    visible_steps =
      steps
      |> Enum.with_index()
      |> Enum.map(fn {step, idx} ->
        Map.put(step, :visible, idx < visible_count)
      end)

    visible_edges =
      Enum.filter(edges, fn edge ->
        MapSet.member?(visible_ids, edge.source) and MapSet.member?(visible_ids, edge.target)
      end)

    push_event(socket, "flowchart_data", %{
      steps: visible_steps,
      edges: visible_edges,
      visible_count: visible_count
    })
  end

  defp step_visible?(step, visible_count) do
    String.to_integer(step.id) <= visible_count
  end

  defp phase_badge_class("setup"), do: "bg-blue-500/20 text-blue-400"
  defp phase_badge_class("loop"), do: "bg-gray-500/20 text-gray-400"
  defp phase_badge_class("decision"), do: "bg-amber-500/20 text-amber-400"
  defp phase_badge_class("done"), do: "bg-green-500/20 text-green-400"
  defp phase_badge_class(_), do: "bg-gray-500/20 text-gray-400"

  defp phase_dot_class("setup"), do: "bg-blue-500"
  defp phase_dot_class("loop"), do: "bg-gray-500"
  defp phase_dot_class("decision"), do: "bg-amber-500"
  defp phase_dot_class("done"), do: "bg-green-500"
  defp phase_dot_class(_), do: "bg-gray-500"

  defp load_ralph_data do
    project =
      try do
        ConfigLoader.get_active_project()
      catch
        :exit, _ -> nil
      end

    prd_path = if project, do: project["prd_json"]

    case Ralph.load(prd_path) do
      {:ok, %{stories: stories} = ralph_data} when stories != [] ->
        # Convert stories to step format for the flowchart
        steps =
          stories
          |> Enum.with_index(1)
          |> Enum.map(fn {story, idx} ->
            phase =
              cond do
                idx <= 2 -> "setup"
                story["passes"] == true -> "done"
                true -> "loop"
              end

            %{
              id: to_string(idx),
              label: story["title"] || "Story #{idx}",
              description: story["description"] || "",
              phase: phase
            }
          end)

        edges =
          steps
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [s, t] -> %{source: s.id, target: t.id} end)

        {steps, edges, ralph_data}

      _ ->
        {@default_steps, @default_edges, nil}
    end
  end
end
