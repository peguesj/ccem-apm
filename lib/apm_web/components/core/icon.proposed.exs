defmodule ApmWeb.Components.Core.Icon do
  @moduledoc """
  Tier 1 primitive — Icon (heroicons + custom APM set).

  Sourced from design-intake/v11.0.0/from-designer/apm-primitives.jsx (I.* icon set).

  Custom APM icon names (all 1.6px stroke, 24×24 viewBox, fill="none"):
    live, search, decide, tune, operate, invest, bolt, spark, bell,
    agent, node, chevron, arrow, plus, close, clock, check, x, ask,
    term, doc, plug, shield, grid, chat, heart.

  Falls back to heroicons for any name not in the custom set.
  Size is controlled by the `size` attribute (px integer, default 14).

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-primitives.jsx → I.* icon set
  """
  use Phoenix.Component

  attr :name, :string, required: true
  attr :size, :integer, default: 14
  attr :rest, :global

  def icon(assigns) do
    ~H"""
    <span
      class={["apm-icon", "apm-icon--#{@name}"]}
      style={"width:#{@size}px;height:#{@size}px;display:inline-flex;flex-shrink:0"}
      aria-hidden="true"
      {@rest}
    >
      <%!-- SVG rendered by CSS mask-image or inline via a helper module. --%>
      <%!-- See ApmWeb.IconHelpers.render/2 (to be implemented in Phase 2+). --%>
    </span>
    """
  end
end
