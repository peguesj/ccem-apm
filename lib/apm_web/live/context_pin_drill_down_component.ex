defmodule ApmWeb.Live.ContextPinDrillDownComponent do
  @moduledoc """
  LiveComponent: collapsible scope context panel rendered below the pinned widget.

  When a widget is pinned as a scope source and a scope value is selected
  (e.g. scope_type: :project, scope_value: "ccem"), this component renders
  a two-section drill-down panel:

  - **Project section** (expanded by default): project-level data relevant to the
    selected scope value. For :project scope, shows project name + summary stats.
  - **User section** (collapsed by default): user/global-level data. A toggle
    button expands/collapses it.

  The component subscribes to `"dashboard:scope:{session_id}"` PubSub topic
  to auto-update when the scope changes. A scope badge is shown in the
  breadcrumb-style header.

  Only renders visible content when `scope_type != :global`.

  ## Attrs

  - `session_id` - string socket id for PubSub subscription (required)
  - `scope_type` - atom: :global | :project | :formation | :agent (required)
  - `scope_value` - string or nil (required)
  - `pinned_widget_id` - string or nil, the currently pinned widget id

  ## Usage

      <.live_component
        module={ApmWeb.Live.ContextPinDrillDownComponent}
        id="context-pin-drill-down"
        session_id={socket.id}
        scope_type={scope_type}
        scope_value={scope_value}
        pinned_widget_id={widget_pinned_id}
      />
  """

  use ApmWeb, :live_component

  alias Apm.{AgentRegistry, ConfigLoader}

  @impl true
  def update(assigns, socket) do
    scope_type = assigns[:scope_type] || :global
    scope_value = assigns[:scope_value]

    project_data =
      if scope_type == :project && is_binary(scope_value) do
        load_project_data(scope_value)
      else
        nil
      end

    {:ok,
     socket
     |> assign(:session_id, assigns[:session_id] || "")
     |> assign(:scope_type, scope_type)
     |> assign(:scope_value, scope_value)
     |> assign(:pinned_widget_id, assigns[:pinned_widget_id])
     |> assign(:user_section_expanded, false)
     |> assign(:project_data, project_data)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="context-pin-drill-down"
      class={if @scope_type == :global || is_nil(@pinned_widget_id), do: "hidden", else: ""}
    >
      <%!-- Scope badge header --%>
      <div class="flex items-center gap-2 px-3 py-1.5 bg-primary/10 border border-primary/20 rounded-lg mb-2">
        <span class="badge badge-primary badge-sm">{scope_label(@scope_type)}</span>
        <span class="text-xs font-medium text-primary truncate">{@scope_value || "—"}</span>
        <button
          phx-click="widget_scope_select"
          phx-value-scope_type="global"
          phx-value-scope_value=""
          class="btn btn-ghost btn-xs ml-auto text-base-content/40 hover:text-error"
          title="Clear scope"
        >
          ✕
        </button>
      </div>

      <%!-- Project section (expanded by default) --%>
      <%= if @scope_type == :project do %>
        <div class="bg-base-200 border border-base-300 rounded-lg mb-1">
          <div class="px-3 py-2">
            <p class="text-xs font-semibold text-base-content mb-1">Project Scope</p>
            <%= if @project_data do %>
              <div class="grid grid-cols-3 gap-2">
                <div class="text-center">
                  <div class="text-lg font-bold text-primary">{@project_data.agent_count}</div>
                  <div class="text-[10px] text-base-content/60">Agents</div>
                </div>
                <div class="text-center">
                  <div class="text-lg font-bold text-secondary">{@project_data.session_count}</div>
                  <div class="text-[10px] text-base-content/60">Sessions</div>
                </div>
                <div class="text-center">
                  <div class={["text-lg font-bold", status_color(@project_data.status)]}>
                    {@project_data.status}
                  </div>
                  <div class="text-[10px] text-base-content/60">Status</div>
                </div>
              </div>
            <% else %>
              <p class="text-xs text-base-content/50 italic">No project data available</p>
            <% end %>
          </div>
        </div>

        <%!-- User section (collapsed by default) --%>
        <div class="bg-base-200 border border-base-300 rounded-lg">
          <button
            phx-click="toggle_user_section"
            phx-target={@myself}
            class="flex items-center justify-between w-full px-3 py-2 text-left"
          >
            <span class="text-xs font-semibold text-base-content/70">User / Global View</span>
            <svg
              class={[
                "w-3.5 h-3.5 text-base-content/40 transition-transform",
                if(@user_section_expanded, do: "rotate-180", else: "")
              ]}
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
          </button>

          <%= if @user_section_expanded do %>
            <div class="px-3 pb-2 border-t border-base-300">
              <p class="text-xs text-base-content/50 italic mt-2">
                Global view — all projects, all sessions. Click a widget to drill back into user scope.
              </p>
              <button
                phx-click="widget_scope_select"
                phx-value-scope_type="global"
                phx-value-scope_value=""
                class="btn btn-outline btn-xs mt-2"
              >
                Switch to Global View
              </button>
            </div>
          <% end %>
        </div>
      <% end %>

      <%!-- Formation scope --%>
      <%= if @scope_type == :formation do %>
        <div class="bg-base-200 border border-base-300 rounded-lg mb-1 px-3 py-2">
          <p class="text-xs font-semibold text-base-content mb-1">Formation Scope</p>
          <p class="text-xs text-base-content/70">
            Formation: <span class="font-mono text-primary">{@scope_value}</span>
          </p>
        </div>
      <% end %>

      <%!-- Agent scope --%>
      <%= if @scope_type == :agent do %>
        <div class="bg-base-200 border border-base-300 rounded-lg mb-1 px-3 py-2">
          <p class="text-xs font-semibold text-base-content mb-1">Agent Scope</p>
          <p class="text-xs text-base-content/70">
            Agent: <span class="font-mono text-success">{@scope_value}</span>
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Event Handlers ────────────────────────────────────────────────────────────

  @impl true
  def handle_event("toggle_user_section", _params, socket) do
    {:noreply, assign(socket, :user_section_expanded, !socket.assigns.user_section_expanded)}
  end

  # ── Private Helpers ───────────────────────────────────────────────────────────

  defp load_project_data(project_name) do
    try do
      config = ConfigLoader.get_config()
      projects = Map.get(config, "projects", [])
      project = Enum.find(projects, &(Map.get(&1, "name") == project_name))

      agents = AgentRegistry.list_agents(project_name)
      agent_count = length(agents)

      session_count =
        agents |> Enum.map(& &1[:session_id]) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length()

      status = if Enum.any?(agents, &(&1.status == "active")), do: "active", else: "idle"

      if project do
        %{
          name: project_name,
          agent_count: agent_count,
          session_count: session_count,
          status: status
        }
      else
        %{name: project_name, agent_count: 0, session_count: 0, status: "unknown"}
      end
    rescue
      _ -> %{name: project_name, agent_count: 0, session_count: 0, status: "unknown"}
    end
  end

  defp scope_label(:project), do: "Project"
  defp scope_label(:formation), do: "Formation"
  defp scope_label(:agent), do: "Agent"
  defp scope_label(_), do: "Scope"

  defp status_color("active"), do: "text-success"
  defp status_color("error"), do: "text-error"
  defp status_color("idle"), do: "text-warning"
  defp status_color(_), do: "text-base-content/60"
end
