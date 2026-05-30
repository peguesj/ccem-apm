defmodule ApmV5Web.Components.Core.Dot do
  @moduledoc """
  Tier 1 primitive — Dot (presence / status indicator).

  Sourced from design-intake/v11.0.0/from-designer/apm-primitives.jsx (Dot).

  Color resolution:
  - If `decoration` is set: uses `var(--apm-decoration-{decoration})` (e.g. "iris").
  - Otherwise: uses `tone(t).fg` → `var(--apm-status-{tone})`.

  `pulse` applies `.apm-pulse` animation (apm-tokens.css keyframe).
  `size` is the pixel diameter (default 7); maps to CSS custom property.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-primitives.jsx → Dot
  """
  use Phoenix.Component

  attr :tone, :string, default: "neutral",
    values: ~w(success warning error info neutral)

  attr :pulse, :boolean, default: false
  attr :size, :integer, default: 7
  attr :decoration, :string, default: nil
  attr :rest, :global

  def dot(assigns) do
    ~H"""
    <span
      class={[
        "apm-dot",
        @decoration && "apm-dot--decoration-#{@decoration}",
        !@decoration && "apm-dot--tone-#{@tone}",
        @pulse && "apm-pulse"
      ]}
      style={"width:#{@size}px;height:#{@size}px"}
      aria-hidden="true"
      {@rest}
    />
    """
  end
end
