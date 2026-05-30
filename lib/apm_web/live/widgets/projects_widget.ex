defmodule ApmWeb.Live.Widgets.ProjectsWidget do
  @moduledoc """
  LiveComponent: Projects widget for the Dashboard Widgetization Engine.

  Displays the list of active projects from Apm.ConfigLoader with per-project
  agent counts, session counts, and status badges. Each project row has a "Select"
  button that, when clicked, broadcasts a project scope to the DashboardScopeEngine
  for the current session — scoping all non-user-level widgets to that project.

  This widget is registered as `pinnable: true` in WidgetRegistry. When pinned,
  selecting a project drives scope for the entire dashboard. When not pinned, scope
  changes affect only the breadcrumb display.

  Subscribes to `"apm:config"` PubSub for live updates when projects change.

  ## Widget Registration

  Registered in WidgetRegistry with:
  - id: "projects"
  - category: :monitoring
  - pinnable: true
  - supported_scopes: ["global", "project"]

  ## Attrs

  - `session_id` - socket.id for DashboardScopeEngine calls (required)
  - `scope_value` - current active project scope value or nil
  - `config` - merged widget config map (default: %{show_inactive: false, compact: false})
  """

  use ApmWeb, :live_component

  alias Apm.{AgentRegistry, ConfigLoader}

  @impl true
  def update(assigns, socket) do
    config = assigns[:config] || %{show_inactive: false, compact: false}
    projects = load_projects(config)

    {:ok,
     socket
     |> assign(:session_id, assigns[:session_id] || "")
     |> assign(:scope_value, assigns[:scope_value])
     |> assign(:config, config)
     |> assign(:projects, projects)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"projects-widget-#{@id}"} class="h-full">
      <div class="overflow-y-auto h-full">
        <%= if Enum.empty?(@projects) do %>
          <div class="flex flex-col items-center justify-center h-24 text-base-content/40">
            <svg class="w-6 h-6 mb-1" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"
                d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"/>
            </svg>
            <p class="text-xs">No projects configured</p>
          </div>
        <% else %>
          <ul class="divide-y divide-base-300">
            <%= for project <- @projects do %>
              <li class={[
                "flex items-center gap-2 px-2 py-1.5 hover:bg-base-300/30 transition-colors group",
                if(@scope_value == project.name, do: "bg-primary/10 border-l-2 border-primary", else: "")
              ]}>
                <%!-- Status indicator --%>
                <div class={["w-2 h-2 rounded-full flex-shrink-0", project_status_color(project.status)]}></div>

                <%!-- Project info --%>
                <div class="flex-1 min-w-0">
                  <div class="text-xs font-medium text-base-content truncate" title={project.name}>
                    {project.name}
                  </div>
                  <%= unless @config[:compact] do %>
                    <div class="flex items-center gap-2 text-[10px] text-base-content/50">
                      <span>{project.agent_count} agents</span>
                      <span>·</span>
                      <span>{project.session_count} sessions</span>
                    </div>
                  <% end %>
                </div>

                <%!-- Select button --%>
                <button
                  phx-click="widget_scope_select"
                  phx-value-scope_type="project"
                  phx-value-scope_value={project.name}
                  class={[
                    "btn btn-xs flex-shrink-0",
                    if(@scope_value == project.name,
                      do: "btn-primary",
                      else: "btn-ghost opacity-0 group-hover:opacity-100"
                    )
                  ]}
                  title={"Scope dashboard to #{project.name}"}
                >
                  {if @scope_value == project.name, do: "Active", else: "Select"}
                </button>
              </li>
            <% end %>
          </ul>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Event Handlers ────────────────────────────────────────────────────────────

  # Note: LiveComponents do not support handle_info/2. PubSub messages are
  # received by the parent LiveView and forwarded via update/2 assigns.
  # The apm:config subscription above is for informational registration only.
  # Live project updates flow through the parent DashboardLive's handle_info/2.

  # ── Private Helpers ───────────────────────────────────────────────────────────

  defp load_projects(config) do
    show_inactive = Map.get(config, :show_inactive) || Map.get(config, "show_inactive") || false

    try do
      raw_config = ConfigLoader.get_config()
      projects = Map.get(raw_config, "projects", [])
      agents = AgentRegistry.list_agents(nil)

      projects
      |> Enum.map(fn project ->
        name = Map.get(project, "name") || Map.get(project, :name) || ""
        project_agents = Enum.filter(agents, &(&1.project == name))

        %{
          name: name,
          agent_count: length(project_agents),
          session_count: length(Enum.uniq_by(project_agents, & &1.session_id)),
          status: if(Enum.any?(project_agents, &(&1.status == "active")), do: "active", else: "idle")
        }
      end)
      |> Enum.reject(fn p -> !show_inactive && p.agent_count == 0 && p.status == "idle" end)
      |> Enum.sort_by(& &1.name)
    rescue
      _ -> []
    end
  end

  defp project_status_color("active"), do: "bg-success"
  defp project_status_color("error"), do: "bg-error"
  defp project_status_color("idle"), do: "bg-base-content/20"
  defp project_status_color(_), do: "bg-base-content/20"
end
