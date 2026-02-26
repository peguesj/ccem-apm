defmodule ApmV4Web.WorkflowLive do
  use ApmV4Web, :live_view

  alias ApmV4.WorkflowRegistry

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
         |> assign(:selected_step, nil)}
    end
  end

  def mount(_params, session, socket) do
    mount(%{"type" => "ralph"}, session, socket)
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
      <!-- Sidebar -->
      <div class="w-56 bg-base-100 border-r border-base-300 flex flex-col flex-shrink-0">
        <div class="p-4 border-b border-base-300">
          <div class="flex items-center gap-2">
            <div class="w-8 h-8 bg-primary rounded-lg flex items-center justify-center">
              <.icon name="hero-cpu-chip" class="w-5 h-5 text-primary-content" />
            </div>
            <span class="font-bold text-lg">APM v4</span>
          </div>
        </div>
        <nav class="flex-1 p-3 space-y-0.5">
          <.nav_item icon="hero-chart-bar-square" label="Dashboard" href="/" />
          <.nav_item icon="hero-squares-2x2" label="All Projects" href="/apm-all" />
          <.nav_item icon="hero-cube-transparent" label="Formation" href="/formation" />
          <.nav_item icon="hero-clock" label="Timeline" href="/timeline" />
          <.nav_item icon="hero-academic-cap" label="Skills" href="/skills" />
          <.nav_item icon="hero-server-stack" label="Ports" href="/ports" />
          <.nav_item icon="hero-book-open" label="Docs" href="/docs" />
          <div class="divider my-1 text-xs text-base-content/30">Workflows</div>
          <%= for wf <- @all_workflows do %>
            <.nav_item
              icon={wf.icon}
              label={wf.title}
              href={"/workflow/#{wf.id}"}
              active={wf.id == @workflow.id}
            />
          <% end %>
        </nav>
      </div>

      <!-- Main content -->
      <div class="flex-1 flex flex-col overflow-hidden">
        <!-- Header -->
        <div class="bg-base-100 border-b border-base-300 px-6 py-3">
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
        </div>

        <!-- Content area -->
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
          <div class="w-72 bg-base-100 border-l border-base-300 flex flex-col">
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
                    ← Back
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
      </div>
    </div>
    """
  end

  defp nav_item(%{active: true} = assigns) do
    ~H"""
    <a href={@href} class="flex items-center gap-2.5 px-3 py-2 rounded-lg text-sm bg-primary text-primary-content font-medium">
      <.icon name={@icon} class="w-4 h-4 flex-shrink-0" />
      <%= @label %>
    </a>
    """
  end

  defp nav_item(assigns) do
    assigns = Map.put_new(assigns, :active, false)
    ~H"""
    <a href={@href} class="flex items-center gap-2.5 px-3 py-2 rounded-lg text-sm text-base-content/70 hover:text-base-content hover:bg-base-200 transition-colors">
      <.icon name={@icon} class="w-4 h-4 flex-shrink-0" />
      <%= @label %>
    </a>
    """
  end
end
