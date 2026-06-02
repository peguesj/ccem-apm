defmodule ApmWeb.Components.Feedback.CountdownRing do
  @moduledoc """
  Tier 4 feedback — CountdownRing (20s TTL arc drain for approval decisions).

  Sourced from design-intake/v11.0.0/from-designer/apm-data.jsx (CountdownRing).

  SVG: two circles at radius = size/2 - 3, rotated -90deg.
  Track: stroke border-default, strokeWidth 2.5.
  Arc: stroke = color(pct), strokeDasharray c, strokeDashoffset c*(1-pct),
    strokeLinecap round, transition stroke-dashoffset 1s linear, stroke 0.3s.

  Color progression (mirrors JSX):
    pct > 0.50 → var(--apm-accent)   (green phase)
    pct > 0.25 → var(--apm-status-warning)
    pct ≤ 0.25 → var(--apm-status-error)

  Center: `apm-mono`, fontSize 12, fontWeight 500, color matches arc color.
  Reduce-motion: numeric countdown only, no arc animation (motion.md §Advanced).

  The CountdownRing JS hook drives the countdown entirely client-side:
  - Reads `data-seconds` on mount
  - Ticks every 1000ms, updates stroke-dashoffset and center text
  - Fires a `countdown_expired` JS event at 0
  `phx-update="ignore"` prevents LiveView from resetting the hook's DOM state.

  ## JS hook
  # TODO: colocate feedback/countdown_ring.hook.js — CountdownRing hook
  # (20s arc drain via stroke-dashoffset, color transitions, expire event)

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-data.jsx → CountdownRing
  - Motion spec: motion.md §Advanced micro-interactions → Countdown ring
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :seconds, :integer, default: 20
  attr :size, :integer, default: 34
  attr :on_expire, :string, default: nil
  attr :rest, :global

  def countdown_ring(assigns) do
    assigns =
      assign(assigns,
        r: assigns.size / 2 - 3,
        cx: assigns.size / 2,
        cy: assigns.size / 2
      )

    assigns = assign(assigns, circ: 2 * :math.pi() * assigns.r)

    ~H"""
    <div
      id={@id}
      class="apm-countdown-ring"
      style={"position:relative;width:#{@size}px;height:#{@size}px"}
      phx-hook="CountdownRing"
      phx-update="ignore"
      data-seconds={@seconds}
      data-expire-event={@on_expire}
      {@rest}
    >
      <svg width={@size} height={@size} style="transform:rotate(-90deg)" aria-hidden="true">
        <circle
          cx={@cx}
          cy={@cy}
          r={@r}
          fill="none"
          stroke="var(--apm-border-default)"
          stroke-width="2.5"
        />
        <circle
          class="apm-countdown-ring__arc"
          cx={@cx}
          cy={@cy}
          r={@r}
          fill="none"
          stroke="var(--apm-accent)"
          stroke-width="2.5"
          stroke-linecap="round"
          stroke-dasharray={@circ}
          stroke-dashoffset="0"
          style="transition:stroke-dashoffset 1s linear,stroke 0.3s"
        />
      </svg>
      <div
        class="apm-countdown-ring__label apm-mono"
        aria-live="polite"
        aria-atomic="true"
        style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:500;color:var(--apm-accent)"
      >
        {@seconds}
      </div>
    </div>
    """
  end
end
