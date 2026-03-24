defmodule ApmV5Web.WorkflowLive do
  @moduledoc """
  LiveView for workflow schema exploration at /workflows.

  Renders Ralph/UPM formation workflow schemas and ship integration
  configurations from WorkflowSchemaStore.

  For the `/workflow/upm` route, a pill-tab bar is shown with two tabs:
  - "Default" — the standard UPM workflow diagram
  - "Current" — live context from UpmStore and ConfigLoader showing active
    phase, wave, formation status, and the stack-appropriate TSC gate command.
  """

  use ApmV5Web, :live_view

  import ApmV5Web.Components.GettingStartedWizard

  alias ApmV5.WorkflowRegistry
  alias ApmV5.UpmStore
  alias ApmV5.ConfigLoader

  @tsc_gate_map %{
    "elixir" => "mix compile --warnings-as-errors",
    "node" => "npx tsc --noEmit",
    "typescript" => "npx tsc --noEmit",
    "python" => "mypy ."
  }

  @spec detect_stack(String.t()) :: String.t()
  defp detect_stack(project_root) do
    cond do
      File.exists?(Path.join(project_root, "mix.exs")) -> "elixir"
      File.exists?(Path.join(project_root, "package.json")) -> "node"
      File.exists?(Path.join(project_root, "requirements.txt")) -> "python"
      File.exists?(Path.join(project_root, "pyproject.toml")) -> "python"
      true -> "elixir"
    end
  end

  @spec build_current_context() :: map()
  defp build_current_context do
    upm_status = UpmStore.get_status()
    config = ConfigLoader.get_config()

    project_root = Map.get(config, "project_root", File.cwd!())

    stack =
      case Map.get(config, "stack") do
        nil -> detect_stack(project_root)
        "" -> detect_stack(project_root)
        s -> s
      end

    tsc_gate = Map.get(@tsc_gate_map, stack, "mix compile --warnings-as-errors")

    formation =
      case UpmStore.get_active_formation() do
        nil -> nil
        f -> f
      end

    active_wave =
      case upm_status do
        %{active: true, session: session} -> Map.get(session, :wave)
        _ -> nil
      end

    active_story =
      case upm_status do
        %{active: true, session: session} -> Map.get(session, :current_story)
        _ -> nil
      end

    phase =
      case upm_status do
        %{active: true, session: session} -> Map.get(session, :phase, "unknown")
        _ -> "idle"
      end

    %{
      upm_active: upm_status.active,
      phase: phase,
      active_wave: active_wave,
      active_story: active_story,
      stack: stack,
      tsc_gate: tsc_gate,
      formation: formation
    }
  end

  def mount(%{"type" => "upm"}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "upm:status")
    end

    case WorkflowRegistry.get_workflow("upm") do
      nil ->
        {:ok, push_navigate(socket, to: "/workflow/ralph")}

      workflow ->
        phase_map = Map.new(workflow.phases, &{&1.id, &1.color})

        steps_with_color =
          Enum.map(workflow.steps, fn step ->
            Map.put(step, :color, Map.get(phase_map, step.phase, "#6366f1"))
          end)

        {:ok,
         socket
         |> assign(:page_title, workflow.title)
         |> assign(:workflow, workflow)
         |> assign(:all_workflows, WorkflowRegistry.list_workflows())
         |> assign(:steps, steps_with_color)
         |> assign(:edges, workflow.edges)
         |> assign(:selected_step, nil)
         |> assign(:active_tab, "default")
         |> assign(:current_context, build_current_context())}
    end
  end

  def mount(%{"type" => type}, _session, socket) do
    case WorkflowRegistry.get_workflow(type) do
      nil ->
        {:ok, push_navigate(socket, to: "/workflow/ralph")}

      workflow ->
        phase_map = Map.new(workflow.phases, &{&1.id, &1.color})

        steps_with_color =
          Enum.map(workflow.steps, fn step ->
            Map.put(step, :color, Map.get(phase_map, step.phase, "#6366f1"))
          end)

        {:ok,
         socket
         |> assign(:page_title, workflow.title)
         |> assign(:workflow, workflow)
         |> assign(:all_workflows, WorkflowRegistry.list_workflows())
         |> assign(:steps, steps_with_color)
         |> assign(:edges, workflow.edges)
         |> assign(:selected_step, nil)
         |> assign(:active_tab, nil)
         |> assign(:current_context, nil)}
    end
  end

  def mount(_params, session, socket) do
    mount(%{"type" => "ralph"}, session, socket)
  end

  def handle_info(_msg, socket) do
    {:noreply, assign(socket, :current_context, build_current_context())}
  end

  def handle_event("set_tab", %{"tab" => tab}, socket) when tab in ["default", "current"] do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("select_step", %{"id" => id}, socket) do
    step = Enum.find(socket.assigns.steps, &(&1.id == id))
    {:noreply, assign(socket, :selected_step, step)}
  end

  def handle_event("clear_step", _params, socket) do
    {:noreply, assign(socket, :selected_step, nil)}
  end

  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <.sidebar_nav current_path="/workflow" />

      <!-- Main content -->
      <div class="flex-1 flex flex-col overflow-hidden">
        <!-- Header -->
        <div class="bg-base-200 border-b border-base-300 px-6 py-3">
          <div class="flex items-center justify-between">
            <div>
              <h1 class="text-lg font-bold"><%= @workflow.title %></h1>
              <p class="text-base-content/60 text-sm"><%= @workflow.description %></p>
            </div>
            <div class="flex items-center gap-2">
              <span class="badge badge-ghost badge-sm"><%= length(@steps) %> steps</span>
              <span class="badge badge-primary badge-sm">Interactive</span>
            </div>
          </div>
          <!-- Pill-tab bar (UPM only) -->
          <%= if @active_tab do %>
            <div class="flex gap-1 mt-3">
              <button
                phx-click="set_tab"
                phx-value-tab="default"
                class={[
                  "px-4 py-1.5 rounded-full text-sm font-medium transition-colors",
                  if(@active_tab == "default",
                    do: "bg-primary text-primary-content",
                    else: "bg-base-300 text-base-content/60 hover:text-base-content"
                  )
                ]}
              >
                Default
              </button>
              <button
                phx-click="set_tab"
                phx-value-tab="current"
                class={[
                  "px-4 py-1.5 rounded-full text-sm font-medium transition-colors",
                  if(@active_tab == "current",
                    do: "bg-primary text-primary-content",
                    else: "bg-base-300 text-base-content/60 hover:text-base-content"
                  )
                ]}
              >
                Current
              </button>
            </div>
          <% end %>
        </div>

        <!-- Content area -->
        <%= if @active_tab == "current" and @current_context do %>
          <.render_current_tab context={@current_context} />
        <% else %>
          <div class="flex-1 flex overflow-hidden">
            <!-- Graph area -->
            <div class="flex-1 relative overflow-hidden">
              <div
                id="workflow-graph"
                phx-hook="WorkflowGraph"
                data-steps={Jason.encode!(@steps)}
                data-edges={Jason.encode!(@edges)}
                class="w-full h-full"
              >
              </div>
            </div>

            <!-- Right panel -->
            <div class="w-72 bg-base-200 border-l border-base-300 flex flex-col">
              <!-- Phase legend -->
              <div class="p-4 border-b border-base-300">
                <h3 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">Phases</h3>
                <div class="space-y-2">
                  <%= for phase <- @workflow.phases do %>
                    <div class="flex items-center gap-2">
                      <div
                        class="w-2.5 h-2.5 rounded-full flex-shrink-0"
                        style={"background-color: #{phase.color}"}
                      ></div>
                      <span class="text-sm"><%= phase.label %></span>
                    </div>
                  <% end %>
                </div>
              </div>

              <!-- Step detail or step list -->
              <%= if @selected_step do %>
                <div class="p-4 flex-1 overflow-y-auto">
                  <div class="flex items-center justify-between mb-3">
                    <h3 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider">Step Detail</h3>
                    <button phx-click="clear_step" class="text-xs text-base-content/40 hover:text-base-content">
                      &larr; Back
                    </button>
                  </div>
                  <div class="bg-base-200 rounded-lg p-4">
                    <div class="flex items-center gap-2 mb-2">
                      <div
                        class="w-6 h-6 rounded-full flex items-center justify-center text-xs font-bold text-white flex-shrink-0"
                        style={"background-color: #{@selected_step.color}"}
                      >
                        <%= @selected_step.id %>
                      </div>
                      <span class="font-semibold"><%= @selected_step.label %></span>
                    </div>
                    <p class="text-base-content/70 text-sm leading-relaxed"><%= @selected_step.description %></p>
                  </div>
                </div>
              <% else %>
                <div class="flex-1 overflow-y-auto p-4">
                  <h3 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">Steps</h3>
                  <div class="space-y-1.5">
                    <%= for step <- @steps do %>
                      <button
                        phx-click="select_step"
                        phx-value-id={step.id}
                        class="w-full text-left bg-base-200 hover:bg-base-300 rounded-lg p-2.5 transition-colors"
                      >
                        <div class="flex items-center gap-2">
                          <div
                            class="w-5 h-5 rounded-full flex items-center justify-center text-xs font-bold text-white flex-shrink-0"
                            style={"background-color: #{step.color}"}
                          >
                            <%= step.id %>
                          </div>
                          <span class="text-sm"><%= step.label %></span>
                        </div>
                      </button>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    <.wizard page="upm" dom_id="ccem-wizard-upm-workflow" />
    """
  end

  defp render_current_tab(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto p-6 space-y-4">
      <!-- UPM Status -->
      <div class="bg-base-200 rounded-xl p-5">
        <h2 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-4">UPM Status</h2>
        <div class="grid grid-cols-2 gap-4">
          <div>
            <p class="text-xs text-base-content/50 mb-1">Active</p>
            <%= if @context.upm_active do %>
              <span class="badge badge-success badge-sm">Active</span>
            <% else %>
              <span class="badge badge-ghost badge-sm">Idle</span>
            <% end %>
          </div>
          <div>
            <p class="text-xs text-base-content/50 mb-1">Phase</p>
            <span class="text-sm font-mono font-medium"><%= @context.phase %></span>
          </div>
          <div>
            <p class="text-xs text-base-content/50 mb-1">Active Wave</p>
            <span class="text-sm font-mono"><%= @context.active_wave || "—" %></span>
          </div>
          <div>
            <p class="text-xs text-base-content/50 mb-1">Active Story</p>
            <span class="text-sm font-mono"><%= @context.active_story || "—" %></span>
          </div>
        </div>
      </div>

      <!-- TSC Gate -->
      <div class="bg-base-200 rounded-xl p-5">
        <h2 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">TSC Gate</h2>
        <div class="flex items-center gap-3">
          <span class="badge badge-outline badge-sm capitalize"><%= @context.stack %></span>
          <code class="text-sm font-mono bg-base-300 px-3 py-1 rounded-lg"><%= @context.tsc_gate %></code>
        </div>
      </div>

      <!-- Formation Status -->
      <div class="bg-base-200 rounded-xl p-5">
        <h2 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">Formation</h2>
        <%= if @context.formation do %>
          <div class="space-y-2">
            <div class="flex items-center justify-between">
              <span class="text-sm text-base-content/70">ID</span>
              <span class="text-sm font-mono"><%= Map.get(@context.formation, :id, "—") %></span>
            </div>
            <div class="flex items-center justify-between">
              <span class="text-sm text-base-content/70">Status</span>
              <span class="badge badge-primary badge-sm"><%= Map.get(@context.formation, :status, "unknown") %></span>
            </div>
            <div class="flex items-center justify-between">
              <span class="text-sm text-base-content/70">Name</span>
              <span class="text-sm"><%= Map.get(@context.formation, :name, "—") %></span>
            </div>
          </div>
        <% else %>
          <p class="text-sm text-base-content/40">No active formation</p>
        <% end %>
      </div>
    </div>
    """
  end

end
