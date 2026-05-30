defmodule ApmWeb.Components.Data.Gauge do
  @moduledoc """
  Tier 3 data-display — Gauge (radial arc meter).

  Sourced from design-intake/v11.0.0/from-designer/apm-data.jsx (Gauge).

  SVG: two circles at radius = size/2 - 6, rotated 135deg.
  Background arc: stroke var(--apm-border-default), strokeWidth 3,
    dasharray c*0.75 c (75% of circumference visible = 270° sweep).
  Foreground arc: stroke {color}, dashoffset = c*(1 - value*0.75),
    strokeLinecap round, transition stroke-dashoffset 200ms var(--apm-ease-out).

  Center overlay: value as percentage (mono, fontSize 18, fontWeight 500,
    letterSpacing -0.03em) + optional label (class `apm-upper`, fontSize 9,
    color text-dim, letterSpacing 0.08em).

  `value` is a float 0.0–1.0. Center renders Math.round(value*100) as integer %.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-data.jsx → Gauge
  """
  use Phoenix.Component

  attr :value, :float, default: 0.6
  attr :label, :string, default: nil
  attr :color, :string, default: "var(--apm-accent)"
  attr :size, :integer, default: 72
  attr :rest, :global

  def gauge(assigns) do
    assigns =
      assign(assigns,
        r: assigns.size / 2 - 6,
        pct: round(assigns.value * 100)
      )

    assigns =
      assign(assigns,
        circ: 2 * :math.pi() * assigns.r,
        cx: assigns.size / 2,
        cy: assigns.size / 2
      )

    assigns =
      assign(assigns,
        dashoffset: assigns.circ * (1 - assigns.value * 0.75)
      )

    ~H"""
    <div
      class="apm-gauge"
      style={"position:relative;width:#{@size}px;height:#{@size}px"}
      {@rest}
    >
      <svg width={@size} height={@size} style="transform:rotate(135deg)">
        <circle
          cx={@cx}
          cy={@cy}
          r={@r}
          fill="none"
          stroke="var(--apm-border-default)"
          stroke-width="3"
          stroke-dasharray={"#{@circ * 0.75} #{@circ}"}
        />
        <circle
          cx={@cx}
          cy={@cy}
          r={@r}
          fill="none"
          stroke={@color}
          stroke-width="3"
          stroke-dasharray={"#{@circ * 0.75} #{@circ}"}
          stroke-dashoffset={@dashoffset}
          stroke-linecap="round"
          style="transition:stroke-dashoffset var(--apm-dur-base) var(--apm-ease-out)"
        />
      </svg>
      <div class="apm-gauge__center">
        <span class="apm-gauge__value apm-mono">
          {@pct}<span class="apm-gauge__unit">%</span>
        </span>
        <%= if @label do %>
          <span class="apm-gauge__label apm-upper">{@label}</span>
        <% end %>
      </div>
    </div>
    """
  end
end
