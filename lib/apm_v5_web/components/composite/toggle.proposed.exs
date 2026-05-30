defmodule ApmV5Web.Components.Composite.Toggle do
  @moduledoc """
  Tier 2 composite — Toggle (on/off switch).

  Sourced from design-intake/v11.0.0/from-designer/apm-primitives.jsx (Toggle).

  Track (button, class `apm-focusable`):
    width 30px, height 17px, padding 2px, borderRadius 999.
    on  → bg var(--apm-accent), border var(--apm-accent)
    off → bg var(--apm-surface-overlay), border var(--apm-border-default)
    transition: all 200ms var(--apm-ease-out) (pseudo-states.md §Toggle).
    disabled → opacity 0.5, cursor not-allowed.

  Knob (span inside):
    width 11px, height 11px, borderRadius 999.
    on  → bg var(--apm-text-inverse), transform translateX(13px)
    off → bg var(--apm-text-muted), transform translateX(0)
    transition: transform 200ms var(--apm-ease-out).

  Wire `phx-click` + `phx-value-value` for LiveView event handling.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-primitives.jsx → Toggle
  - Pseudo-state matrix: pseudo-states.md §Toggle
  """
  use Phoenix.Component

  attr :on, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :on_change, :string, default: nil
  attr :rest, :global

  def toggle(assigns) do
    ~H"""
    <button
      class={[
        "apm-toggle",
        @on && "apm-toggle--on",
        @disabled && "apm-toggle--disabled",
        "apm-focusable"
      ]}
      type="button"
      disabled={@disabled}
      phx-click={@on_change}
      phx-value-value={!@on}
      role="switch"
      aria-checked={to_string(@on)}
      {@rest}
    >
      <span class="apm-toggle__knob" aria-hidden="true" />
    </button>
    """
  end
end
