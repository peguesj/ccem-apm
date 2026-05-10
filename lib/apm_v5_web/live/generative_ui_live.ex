defmodule ApmV5Web.GenerativeUILive do
  @moduledoc """
  Dynamically renders agent-registered UI components.

  ## US-024 Acceptance Criteria (DoD):
  - Mounted at /generative-ui
  - Renders all registered components from GenerativeUI.Registry
  - Component renderer dispatches on type
  - EventBus subscription for 'special:custom' generative_ui_update events
  - Agent filter dropdown
  - Nav item in sidebar
  - mix compile --warnings-as-errors passes
  """

  use ApmV5Web, :live_view

  import ApmV5Web.Components.GettingStartedWizard

  alias ApmV5.AgUi.GenerativeUI.Registry
  alias ApmV5.AgUi.EventBus

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      EventBus.subscribe("special:custom")
    end

    components = Registry.list_components()

    {:ok,
     socket
     |> assign(:page_title, "Generative UI")
     |> assign(:components, components)
     |> assign(:agent_filter, nil)
     |> assign(:sidebar_collapsed, false)
     |> assign(:inspector_open, false)
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  @impl true
  def handle_info({:event_bus, _topic, %{data: %{name: "generative_ui_update"}}}, socket) do
    components = Registry.list_components()
    {:noreply, assign(socket, :components, components)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter_agent", %{"agent" => agent}, socket) do
    filter = if agent == "", do: nil, else: agent
    {:noreply, assign(socket, :agent_filter, filter)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav current_path="/generative-ui" />
      </:sidebar>
      <:main>

      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0 relative z-10">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Generative UI</h2>
            <div class="badge badge-sm badge-primary"><%= length(@components) %> components</div>
          </div>
        </header>

        <div class="flex-1 overflow-y-auto p-6 space-y-6">
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            <%= for comp <- filtered_components(@components, @agent_filter) do %>
              <div class="card bg-base-200 shadow-xl">
                <div class="card-body">
                  <h3 class="card-title text-sm">
                    <span class={type_badge(comp.type)}><%= comp.type %></span>
                    <%= comp.title || comp.id %>
                  </h3>
                  <p class="text-xs opacity-60">Agent: <%= comp.agent_id %></p>
                  <%= render_component(comp, assigns) %>
                </div>
              </div>
            <% end %>
            <%= if Enum.empty?(@components) do %>
              <div class="col-span-full text-center py-12 opacity-50">
                <p>No components registered. Agents can register dynamic UI via POST /api/v2/generative-ui/components</p>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    <.wizard page="ag-ui" dom_id="ccem-wizard-ag-ui-genui" />
      </:main>
    </.page_layout>
    """
  end

  defp filtered_components(comps, nil), do: comps
  defp filtered_components(comps, agent_id) do
    Enum.filter(comps, & &1.agent_id == agent_id)
  end

  defp type_badge("card"), do: "badge badge-primary badge-sm"
  defp type_badge("chart"), do: "badge badge-secondary badge-sm"
  defp type_badge("table"), do: "badge badge-accent badge-sm"
  defp type_badge("alert"), do: "badge badge-warning badge-sm"
  defp type_badge("progress"), do: "badge badge-info badge-sm"
  defp type_badge(_), do: "badge badge-ghost badge-sm"

  defp render_component(%{type: "card", props: props}, _assigns) do
    assigns = %{props: props}

    ~H"""
    <div class="stat">
      <div class="stat-title"><%= @props["label"] || "Value" %></div>
      <div class="stat-value"><%= @props["value"] || "-" %></div>
      <div :if={@props["description"]} class="stat-desc"><%= @props["description"] %></div>
    </div>
    """
  end

  defp render_component(%{type: "alert", props: props}, _assigns) do
    assigns = %{props: props}

    ~H"""
    <div class={"alert alert-#{@props["level"] || "info"}"}>
      <span><%= @props["message"] || "" %></span>
    </div>
    """
  end

  defp render_component(%{type: "progress", props: props}, _assigns) do
    assigns = %{props: props}

    ~H"""
    <div>
      <div class="flex justify-between text-sm mb-1">
        <span><%= @props["label"] || "Progress" %></span>
        <span><%= @props["value"] || 0 %>%</span>
      </div>
      <progress class="progress progress-primary" value={@props["value"] || 0} max="100"></progress>
    </div>
    """
  end

  defp render_component(%{props: props}, _assigns) do
    assigns = %{props: props}

    ~H"""
    <pre class="text-xs bg-base-300 p-2 rounded overflow-auto max-h-32"><%= Jason.encode!(@props, pretty: true) %></pre>
    """
  end
end
