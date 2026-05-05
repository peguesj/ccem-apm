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
    upm_status = try do UpmStore.get_status() rescue _ -> %{active: false} catch :exit, _ -> %{active: false} end
    config = try do ConfigLoader.get_config() rescue _ -> %{} catch :exit, _ -> %{} end

    project_root = Map.get(config, "project_root", File.cwd!())

    stack =
      case Map.get(config, "stack") do
        nil -> detect_stack(project_root)
        "" -> detect_stack(project_root)
        s -> s
      end

    tsc_gate = Map.get(@tsc_gate_map, stack, "mix compile --warnings-as-errors")

    formation =
      try do
        UpmStore.get_active_formation()
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
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

    case (try do WorkflowRegistry.get_workflow("upm") rescue _ -> nil catch :exit, _ -> nil end) do
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
         |> assign(:all_workflows, (try do WorkflowRegistry.list_workflows() rescue _ -> [] catch :exit, _ -> [] end))
         |> assign(:steps, steps_with_color)
         |> assign(:edges, workflow.edges)
         |> assign(:selected_step, nil)
         |> assign(:active_tab, "default")
         |> assign(:current_context, build_current_context())
         |> assign(:inspector_open, false)
         |> assign(:selected_story, nil)
         |> assign(:sidebar_collapsed, false)
         |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
    end
  end

  def mount(%{"type" => type}, _session, socket) do
    case (try do WorkflowRegistry.get_workflow(type) rescue _ -> nil catch :exit, _ -> nil end) do
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
         |> assign(:all_workflows, (try do WorkflowRegistry.list_workflows() rescue _ -> [] catch :exit, _ -> [] end))
         |> assign(:steps, steps_with_color)
         |> assign(:edges, workflow.edges)
         |> assign(:selected_step, nil)
         |> assign(:active_tab, nil)
         |> assign(:current_context, nil)
         |> assign(:inspector_open, false)
         |> assign(:selected_story, nil)
         |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
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

  def handle_event("toggle_inspector", _params, socket) do
    {:noreply, assign(socket, :inspector_open, !socket.assigns.inspector_open)}
  end

  def handle_event("select_story", %{"id" => story_id}, socket) do
    story = find_story(socket.assigns, story_id)
    {:noreply, assign(socket, selected_story: story, inspector_open: true)}
  end

  def handle_event("close_inspector", _params, socket) do
    {:noreply, assign(socket, inspector_open: false)}
  end

  # --- Private Helpers ---

  @spec find_story(map(), String.t()) :: map() | nil
  defp find_story(assigns, story_id) do
    stories =
      case assigns do
        %{current_context: %{formation: %{stories: stories}}} when is_list(stories) ->
          stories

        %{current_context: %{active_story: _}} ->
          # Pull stories from UpmStore active session
          case ApmV5.UpmStore.get_status() do
            %{active: true, session: %{stories: stories}} -> stories
            _ -> []
          end

        _ ->
          []
      end

    Enum.find(stories, &(to_string(Map.get(&1, :id)) == story_id))
  end

  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav current_path="/workflow" />
      </:sidebar>
      <:main>

      <!-- Main content -->
      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0 relative z-10">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content"><%= @workflow.title %></h2>
            <div class="badge badge-sm badge-ghost"><%= length(@steps) %> steps</div>
            <span class="badge badge-primary badge-sm">Interactive</span>
          </div>
          <div class="flex items-center gap-2">
            <%= if @active_tab == "current" do %>
              <button
                phx-click="toggle_inspector"
                class={["btn btn-ghost btn-xs gap-1", @inspector_open && "btn-active"]}
                title="Toggle inspector"
              >
                <.icon name="hero-bars-3-bottom-right" class="w-4 h-4" />
                Inspector
              </button>
            <% end %>
          </div>
        </header>
        <div class="bg-base-200 border-b border-base-300 px-4 py-1 flex-shrink-0">
          <!-- Pill-tab bar (UPM only) -->
          <%= if @active_tab do %>
            <div class="flex gap-1">
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
          <.render_current_tab
            context={@current_context}
            inspector_open={@inspector_open}
            selected_story={@selected_story}
          />
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
    <.wizard page="upm" dom_id="ccem-wizard-upm-workflow" />
      </:main>
    </.page_layout>
    """
  end

  defp render_current_tab(assigns) do
    # Resolve stories from the UPM session for the plan view
    stories =
      case ApmV5.UpmStore.get_status() do
        %{active: true, session: %{stories: s}} when is_list(s) -> s
        _ -> []
      end

    assigns = assign(assigns, :stories, stories)

    ~H"""
    <div class="flex flex-1 overflow-hidden">
      <!-- Main scrollable panel -->
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

        <!-- Stories Plan View -->
        <%= if @stories != [] do %>
          <div class="bg-base-200 rounded-xl p-5">
            <h2 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">
              Stories
              <span class="ml-2 badge badge-ghost badge-xs"><%= length(@stories) %></span>
            </h2>
            <div class="space-y-1.5">
              <%= for story <- @stories do %>
                <button
                  phx-click="select_story"
                  phx-value-id={story.id}
                  class={[
                    "w-full text-left rounded-lg px-3 py-2.5 transition-colors flex items-center gap-3",
                    if(@selected_story && Map.get(@selected_story, :id) == story.id,
                      do: "bg-primary/10 border border-primary/30",
                      else: "bg-base-300 hover:bg-base-100/50"
                    )
                  ]}
                >
                  <span class={[
                    "inline-flex items-center justify-center w-2 h-2 rounded-full flex-shrink-0",
                    case story.status do
                      "passed" -> "bg-success"
                      "failed" -> "bg-error"
                      "in_progress" -> "bg-warning"
                      _ -> "bg-base-content/20"
                    end
                  ]}></span>
                  <span class="text-sm font-mono text-base-content/50 flex-shrink-0"><%= story.id %></span>
                  <span class="text-sm flex-1 truncate"><%= story.title || story.id %></span>
                  <span class={[
                    "badge badge-xs flex-shrink-0",
                    case story.status do
                      "passed" -> "badge-success"
                      "failed" -> "badge-error"
                      "in_progress" -> "badge-warning"
                      _ -> "badge-ghost"
                    end
                  ]}><%= story.status %></span>
                  <.icon name="hero-chevron-right" class="w-3.5 h-3.5 text-base-content/30 flex-shrink-0" />
                </button>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>

      <!-- Pull-out inspector column -->
      <%= if @inspector_open do %>
        <div
          id="upm-inspector"
          class="w-96 flex-shrink-0 border-l border-base-300 bg-base-200 overflow-y-auto flex flex-col"
          style="transition: width 300ms ease;"
        >
          <!-- Inspector header -->
          <div class="flex items-center justify-between px-4 py-3 border-b border-base-300 sticky top-0 bg-base-200 z-10">
            <h3 class="font-semibold text-sm">Inspector</h3>
            <button phx-click="close_inspector" class="btn btn-ghost btn-xs btn-circle" title="Close inspector">
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>

          <!-- Inspector body -->
          <%= if @selected_story do %>
            <div class="p-4 space-y-4">
              <!-- Title -->
              <div>
                <div class="text-xs text-base-content/50 uppercase tracking-wide mb-1">Story</div>
                <p class="font-medium text-sm leading-snug">
                  <%= @selected_story.title || @selected_story.id %>
                </p>
              </div>

              <!-- ID -->
              <div>
                <div class="text-xs text-base-content/50 uppercase tracking-wide mb-1">ID</div>
                <span class="text-xs font-mono bg-base-300 px-2 py-0.5 rounded">
                  <%= @selected_story.id %>
                </span>
              </div>

              <!-- Status -->
              <div>
                <div class="text-xs text-base-content/50 uppercase tracking-wide mb-1">Status</div>
                <span class={[
                  "badge badge-sm",
                  case Map.get(@selected_story, :status) do
                    "passed" -> "badge-success"
                    "failed" -> "badge-error"
                    "in_progress" -> "badge-warning"
                    _ -> "badge-ghost"
                  end
                ]}>
                  <%= Map.get(@selected_story, :status, "pending") %>
                </span>
              </div>

              <!-- Agent -->
              <%= if Map.get(@selected_story, :agent_id) do %>
                <div>
                  <div class="text-xs text-base-content/50 uppercase tracking-wide mb-1">Agent</div>
                  <span class="text-xs font-mono text-base-content/70"><%= @selected_story.agent_id %></span>
                </div>
              <% end %>

              <!-- Plane PM link -->
              <%= if Map.get(@selected_story, :plane_issue_id) do %>
                <div>
                  <div class="text-xs text-base-content/50 uppercase tracking-wide mb-1">Plane PM</div>
                  <a
                    href={"https://plane.lgtm.build/lgtm/projects/a20e1d2e-3139-406e-ae03-dc6d1d8cb995/issues/#{@selected_story.plane_issue_id}"}
                    target="_blank"
                    rel="noopener"
                    class="btn btn-ghost btn-xs gap-1"
                  >
                    <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
                    View in Plane PM
                  </a>
                </div>
              <% end %>
            </div>
          <% else %>
            <div class="flex-1 flex items-center justify-center text-base-content/30 text-sm p-8 text-center">
              Select a story to inspect
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

end
