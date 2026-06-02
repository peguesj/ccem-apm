defmodule ApmWeb.Components.Core.Button do
  @moduledoc """
  Tier 1 primitive — Button.

  Sourced from design-intake/v11.0.0/from-designer/apm-primitives.jsx (Btn).
  Pseudo-states via CSS classes (see pseudo-states.md), not per-call style.
  Transition: background, border-color, color, transform 120ms var(--apm-ease-out).

  Variants:
  - primary: bg accent/fg text-inverse; selected → accent-dim
  - secondary: bg surface-raised/border-default → surface-overlay/border-strong on hover
  - ghost: transparent → surface-overlay on hover; fg text-muted → text-primary
  - outline: transparent/border-default → surface-overlay on hover
  - danger: status-error-soft/status-error/oklch(0.68 0.21 25 / 0.4) border

  Loading state: inline spinner (width:12 height:12 border:1.5px currentColor,
  borderTopColor:transparent, animation:apm-spin 0.7s linear infinite), cursor:progress.
  Disabled: opacity 0.45, cursor:not-allowed.
  Active: transform translateY(0.5px).

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-primitives.jsx → Btn
  - Pseudo-state matrix: pseudo-states.md
  """
  use Phoenix.Component

  import ApmWeb.Components.Core.Icon, only: [icon: 1]

  attr :variant, :string, default: "secondary",
    values: ~w(primary secondary ghost outline danger)

  attr :size, :string, default: "md", values: ~w(xs sm md lg)
  attr :tone, :string, default: nil
  attr :icon, :string, default: nil
  attr :icon_right, :string, default: nil
  attr :loading, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :selected, :boolean, default: false
  attr :title, :string, default: nil
  attr :rest, :global

  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      class={[
        "apm-btn",
        "apm-btn--variant-#{@variant}",
        "apm-btn--size-#{@size}",
        @tone && "apm-btn--tone-#{@tone}",
        @loading && "apm-btn--loading",
        @disabled && "apm-btn--disabled",
        @selected && "apm-btn--selected",
        "apm-focusable"
      ]}
      disabled={@disabled || @loading}
      title={@title}
      {@rest}
    >
      <%= if @loading do %>
        <span class="apm-btn__spinner" aria-hidden="true" />
      <% end %>
      <%= if @icon && !@loading do %>
        <span class="apm-btn__icon apm-btn__icon--leading"><.icon name={@icon} /></span>
      <% end %>
      <%= render_slot(@inner_block) %>
      <%= if @icon_right do %>
        <span class="apm-btn__icon apm-btn__icon--trailing"><.icon name={@icon_right} /></span>
      <% end %>
    </button>
    """
  end
end
