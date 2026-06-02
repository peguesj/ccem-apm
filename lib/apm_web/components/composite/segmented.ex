defmodule ApmWeb.Components.Composite.Segmented do
  @moduledoc """
  Tier 2 composite — Segmented control.

  Sourced from design-intake/v11.0.0/from-designer/apm-primitives.jsx (Segmented).

  Container: inline-flex, padding 2px, gap 1px,
    bg var(--apm-surface-base), border 1px solid var(--apm-border-subtle),
    borderRadius var(--apm-r-md).

  Each option button (class `apm-focusable`):
    size sm → padding 2px 8px, fontSize 11
    size md → padding 3px 10px, fontSize 11.5
    selected → bg var(--apm-surface-overlay), color var(--apm-text-primary)
    default  → bg transparent, color var(--apm-text-dim)
    transition: all 120ms var(--apm-ease-out) (pseudo-states.md §Segmented control item).

  `options` is a list of maps with `value` and `label` keys.
  Wire `phx-click` + `phx-value-value` on each button for LiveView event handling.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-primitives.jsx → Segmented
  - Pseudo-state matrix: pseudo-states.md §Segmented control item
  """
  use Phoenix.Component

  attr :options, :list, required: true
  attr :value, :string, required: true
  attr :size, :string, default: "md", values: ~w(sm md)
  attr :on_change, :string, default: nil
  attr :rest, :global

  def segmented(assigns) do
    ~H"""
    <div class={["apm-segmented", "apm-segmented--#{@size}"]} {@rest}>
      <%= for opt <- @options do %>
        <button
          class={[
            "apm-segmented__item",
            "apm-focusable",
            @value == opt.value && "apm-segmented__item--selected"
          ]}
          phx-click={@on_change}
          phx-value-value={opt.value}
          type="button"
        >
          {opt.label}
        </button>
      <% end %>
    </div>
    """
  end
end
