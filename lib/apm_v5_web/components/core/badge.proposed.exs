defmodule ApmV5Web.Components.Core.Badge do
  @moduledoc """
  Tier 1 primitive — Badge.

  Sourced from design-intake/v11.0.0/from-designer/apm-primitives.jsx (Badge).
  Non-interactive — no hover/focus states. Tone restricted to the canonical 5.

  Soft mode (default): bg status-{tone}-soft, fg status-{tone}, border {tone}@40%.
  Prominent mode: bg status-{tone}, fg text-inverse, border {tone}.
  Tone flip: 150ms color/background CSS interpolation, no shape change (pseudo-states.md).

  `dot` + `pulse` renders a 6px dot with `.apm-pulse` animation. Font switches to
  mono when `dot` is true (apm-primitives.jsx Badge).

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-primitives.jsx → Badge
  - Pseudo-state matrix: pseudo-states.md §Badge
  """
  use Phoenix.Component

  attr :tone, :string, default: "neutral",
    values: ~w(success warning error info neutral)

  attr :prominent, :boolean, default: false
  attr :dot, :boolean, default: false
  attr :pulse, :boolean, default: false
  attr :rest, :global

  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span
      class={[
        "apm-badge",
        "apm-badge--#{@tone}",
        @prominent && "apm-badge--prominent",
        @dot && "apm-badge--has-dot apm-mono",
        "apm-badge--transition"
      ]}
      {@rest}
    >
      <%= if @dot do %>
        <span class={["apm-badge__dot", @pulse && "apm-pulse"]} aria-hidden="true" />
      <% end %>
      <%= render_slot(@inner_block) %>
    </span>
    """
  end
end
