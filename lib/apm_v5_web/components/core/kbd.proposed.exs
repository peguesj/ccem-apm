defmodule ApmV5Web.Components.Core.Kbd do
  @moduledoc """
  Tier 1 primitive — Kbd (keyboard shortcut chip).

  Sourced from design-intake/v11.0.0/from-designer/apm-primitives.jsx (Kbd).

  Styles (CSS class `apm-kbd`):
    display: inline-flex; align-items: center; justify-content: center;
    min-width: 18px; height: 18px; padding: 0 5px; font-size: 10px; font-weight: 500;
    color: var(--apm-text-muted); background: var(--apm-surface-overlay);
    border: 1px solid var(--apm-border-default); border-bottom-width: 2px;
    border-radius: var(--apm-r-xs); font-family: var(--apm-font-mono).

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-primitives.jsx → Kbd
  """
  use Phoenix.Component

  attr :rest, :global

  slot :inner_block, required: true

  def kbd(assigns) do
    ~H"""
    <span class="apm-kbd apm-mono" {@rest}>
      <%= render_slot(@inner_block) %>
    </span>
    """
  end
end
