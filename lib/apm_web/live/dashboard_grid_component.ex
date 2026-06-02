defmodule ApmWeb.Live.DashboardGridComponent do
  @moduledoc """
  LiveComponent: CSS Grid 12-column layout container for dashboard widgets.

  Renders widgets according to a layout preset's placements from LayoutStore.
  Each widget cell has a `data-widget-id` attribute consumed by the DashboardGrid
  JS hook for drag-to-reorder via Sortable.js.

  The grid container uses `phx-hook="DashboardGrid"` and the inner container uses
  `phx-update="ignore"` so Sortable.js can reorder DOM children without LiveView
  undoing the changes. On drag-end, the hook fires `layout_reorder` to DashboardLive
  with the new widget order.

  ## Attrs

  - `placements` - list of placement maps from LayoutStore (required)
  - `widget_pinned_id` - string or nil, the currently pinned widget id
  - `widget_edit_panel_id` - string or nil, the widget currently in edit mode
  - `widget_scope_type` - atom, current scope type
  - `widget_scope_value` - string or nil, current scope value
  - `session_configs` - map of widget_id => config from WidgetConfigStore

  ## Slot

  - `widget` - a named slot called for each placement, receives `widget`, `config`,
    `is_pinned`, `is_edit_open` assigns. Must render widget content.

  ## Usage

      <.live_component
        module={ApmWeb.Live.DashboardGridComponent}
        id="dashboard-grid"
        placements={@layout_placements}
        widget_pinned_id={@widget_pinned_id}
        widget_edit_panel_id={@widget_edit_panel_id}
        widget_scope_type={@widget_scope_type}
        widget_scope_value={@widget_scope_value}
        session_configs={@session_configs}
      >
        <:widget :let={slot_assigns}>
          <!-- render your widget using slot_assigns.widget, slot_assigns.config, etc. -->
        </:widget>
      </.live_component>
  """

  use ApmWeb, :live_component

  alias Apm.WidgetRegistry

  @impl true
  def update(assigns, socket) do
    placements = assigns[:placements] || []
    session_configs = assigns[:session_configs] || %{}

    # Hydrate placements with widget definitions
    hydrated =
      Enum.map(placements, fn placement ->
        widget = WidgetRegistry.get_widget(placement.widget_id)
        config = Map.get(session_configs, placement.widget_id) || %{}
        %{placement: placement, widget: widget, config: config}
      end)
      |> Enum.filter(&(&1.widget != nil))

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:hydrated_placements, hydrated)
     |> assign(:widget_scope_type, assigns[:widget_scope_type] || :global)}
  end

  slot :widget, required: true

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="dashboard-grid-outer"
      phx-hook="DashboardGrid"
      class="w-full"
    >
      <div
        id="dashboard-grid-inner"
        phx-update="ignore"
        class="grid grid-cols-12 gap-3 auto-rows-min"
      >
        <%= for %{placement: placement, widget: widget, config: config} <- @hydrated_placements do %>
          <div
            id={"grid-cell-#{widget.id}"}
            data-widget-id={widget.id}
            class={[
              "col-span-#{placement.col_end - placement.col_start}",
              "row-span-#{placement.row_end - placement.row_start}",
              "cursor-grab active:cursor-grabbing"
            ]}
            style={"grid-column: #{placement.col_start} / #{placement.col_end}; grid-row: #{placement.row_start} / #{placement.row_end};"}
          >
            {render_slot(@widget, %{
              widget: widget,
              config: config,
              placement: placement,
              is_pinned: @widget_pinned_id == widget.id,
              is_edit_open: @widget_edit_panel_id == widget.id,
              scope_type: @widget_scope_type,
              scope_value: @widget_scope_value
            })}
          </div>
        <% end %>
      </div>
    </div>
    """
  end

end
