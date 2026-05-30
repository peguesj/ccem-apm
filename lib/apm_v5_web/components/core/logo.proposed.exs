defmodule ApmV5Web.Components.Core.Logo do
  @moduledoc """
  Tier 1 primitive — Logo (APM mark).

  Sourced from design-intake/v11.0.0/from-designer/apm-primitives.jsx (Logo).

  Inline SVG mark: accent-filled center circle (r=4.5) + two arc paths at
  radii 12 and 16 (second at opacity 0.5) + accent dot at cx=32 cy=20.
  Container: borderRadius = size * 0.24; overflow hidden.

  `inverse` mode: stroke var(--apm-text-inverse), bg var(--apm-text-inverse),
  border rgba(0,0,0,0.1).
  Default: stroke var(--apm-text-primary), bg var(--apm-surface-overlay),
  border var(--apm-border-default).

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-primitives.jsx → Logo
  """
  use Phoenix.Component

  attr :size, :integer, default: 22
  attr :inverse, :boolean, default: false
  attr :rest, :global

  def logo(assigns) do
    ~H"""
    <div
      class={["apm-logo", @inverse && "apm-logo--inverse"]}
      style={"width:#{@size}px;height:#{@size}px;border-radius:#{round(@size * 0.24)}px;position:relative;overflow:hidden;flex-shrink:0"}
      {@rest}
    >
      <svg width={@size} height={@size} viewBox="0 0 40 40" style="position:absolute;inset:0" aria-label="APM">
        <circle cx="20" cy="20" r="4.5" fill="var(--apm-accent)" />
        <path
          d="M 20 8 A 12 12 0 0 1 32 20"
          fill="none"
          stroke={if @inverse, do: "var(--apm-text-inverse)", else: "var(--apm-text-primary)"}
          stroke-width="1.7"
          stroke-linecap="round"
        />
        <path
          d="M 20 4 A 16 16 0 0 1 36 20"
          fill="none"
          stroke={if @inverse, do: "var(--apm-text-inverse)", else: "var(--apm-text-primary)"}
          stroke-width="1.7"
          stroke-linecap="round"
          opacity="0.5"
        />
        <circle cx="32" cy="20" r="1.4" fill="var(--apm-accent)" />
      </svg>
    </div>
    """
  end
end
