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

  ## Implementation choice (Phase 2)

  Icons are rendered as **inline SVG** via `ApmWeb.IconHelpers.render/2`.
  The inline approach was chosen over CSS mask-image sprites because:
  1. Mask-image requires a sprite asset build step not yet in the asset pipeline.
  2. Inline SVGs are immediately colorable via `currentColor` with no extra CSS.
  3. Phase 3+ can migrate to sprite with no component API change (implementation detail).

  TODO (Phase 3): switch `ApmWeb.IconHelpers` to a CSS sprite once
  `assets/icons/apm-sprite.svg` is generated; the component API is unchanged.

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
      style={"width:#{@size}px;height:#{@size}px;display:inline-flex;align-items:center;justify-content:center;flex-shrink:0"}
      aria-hidden="true"
      {@rest}
    >
      {Phoenix.HTML.raw(ApmWeb.IconHelpers.render(@name, @size))}
    </span>
    """
  end
end
