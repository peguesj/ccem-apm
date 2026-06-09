defmodule ApmWeb.Components.Feedback.EmptyState do
  @moduledoc """
  Tier 4 feedback — EmptyState (zero-content placeholder).

  Sourced from design-intake/v11.0.0/from-designer/apm-data.jsx (EmptyState).
  Reused as the default slot content in all Tier-3 data components.

  Layout: flex column, alignItems center, justifyContent center,
    gap 10, padding 48px 24px, textAlign center.

  Icon container: width 40, height 40, borderRadius r-lg,
    bg surface-overlay, display flex center, color text-dim.
  Title: fontSize 14, fontWeight 500, color text-primary.
  Body: fontSize 12.5, color text-dim, maxWidth 320, lineHeight 1.5.
  Action: marginTop 4 (renders the `:action` slot).

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-data.jsx → EmptyState
  """
  use Phoenix.Component

  attr :icon, :string, default: "grid"
  attr :title, :string, required: true
  attr :body, :string, default: nil
  attr :rest, :global

  slot :action

  def empty_state(assigns) do
    ~H"""
    <div class="apm-empty-state" {@rest}>
      <div class="apm-empty-state__icon" aria-hidden="true">
        <ApmWeb.Components.Core.Icon.icon name={@icon} size={20} />
      </div>
      <div class="apm-empty-state__title">{@title}</div>
      <%= if @body do %>
        <div class="apm-empty-state__body">{@body}</div>
      <% end %>
      <%= if @action != [] do %>
        <div class="apm-empty-state__action">
          {render_slot(@action)}
        </div>
      <% end %>
    </div>
    """
  end
end
