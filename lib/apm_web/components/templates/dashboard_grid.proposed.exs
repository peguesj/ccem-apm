defmodule ApmWeb.Components.Templates.DashboardGrid do
  @moduledoc """
  Tier 5 template — DashboardGrid (12-column CSS Grid widget layout).

  Sourced from design-intake/v11.0.0/from-designer/apm-shell.jsx.
  Used by: DashboardLive, HealthLive.
  Extends: DashboardGridComponent (CP-100, widgetization engine).

  Layout: CSS Grid 12-column, gap 16px, padding 20px.
  Each widget placed via `grid-column: span {cols}` and `grid-row: span {rows}`.
  Widget placements read from LayoutStore (via assigns from the parent LiveView).

  Widget slots: the `inner_block` slot renders widget containers
  (typically WidgetContainerComponent LiveComponents wrapping StatTile,
  Sparkline, Gauge, Graph, DataTable etc.).

  Drag-reorder: the DashboardGrid JS hook handles native HTML5 drag-and-drop
  for widget reordering. It emits a `layout_reorder` phx event with the new
  column positions. See CP-103 (DashboardGrid JS hook).

  `gap` and `padding` are configurable for density variants (default/compact).

  ## JS hook
  # TODO: colocate templates/dashboard_grid.hook.js — DashboardGrid drag-reorder
  # (native HTML5 drag, pushEvent layout_reorder) — ships CP-103 reference.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md — DashboardGrid
  - JSX source: apm-shell.jsx — Dashboard/Health screens
  - Widgetization engine: CP-100 DashboardGridComponent (already shipped)
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :gap, :integer, default: 16
  attr :padding, :integer, default: 20
  attr :cols, :integer, default: 12
  attr :on_layout_reorder, :string, default: "layout_reorder"
  attr :rest, :global

  slot :inner_block, required: true

  def dashboard_grid(assigns) do
    ~H"""
    <div
      id={@id}
      class="apm-dashboard-grid"
      style={"display:grid;grid-template-columns:repeat(#{@cols},1fr);gap:#{@gap}px;padding:#{@padding}px;align-items:start"}
      phx-hook="DashboardGrid"
      data-reorder-event={@on_layout_reorder}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end
end
