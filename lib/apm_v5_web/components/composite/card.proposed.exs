defmodule ApmV5Web.Components.Composite.Card do
  @moduledoc """
  Tier 2 composite — Card.

  Sourced from design-intake/v11.0.0/from-designer/apm-primitives.jsx (Card).

  Container: bg var(--apm-surface-raised), border 1px solid var(--apm-border-subtle),
  borderRadius var(--apm-r-lg), overflow hidden.

  Header (rendered when title, kicker, or :action slot present):
    padding 10px 14px, borderBottom 1px solid var(--apm-border-subtle)
    (omitted when `flush` is true).
  Kicker: class `apm-mono apm-upper`, fontSize 10, color var(--apm-text-dim),
    letterSpacing 0.1em.
  Title: fontSize 13, fontWeight 500, color var(--apm-text-primary).
  Subtitle: fontSize 11.5, color var(--apm-text-dim).

  Density:
    compact → 12px body padding
    comfortable → 20px body padding
    default → 16px body padding

  Flush mode: no header border, no body padding.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-primitives.jsx → Card
  - Pseudo-state matrix: pseudo-states.md §Card
  """
  use Phoenix.Component

  attr :kicker, :string, default: nil
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :density, :string, default: "default", values: ~w(compact default comfortable)
  attr :flush, :boolean, default: false
  attr :rest, :global

  slot :action
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div class={["apm-card", "apm-card--density-#{@density}", @flush && "apm-card--flush"]} {@rest}>
      <%= if @title || @kicker || @action != [] do %>
        <div class="apm-card__header">
          <div class="apm-card__header-copy">
            <%= if @kicker do %>
              <div class="apm-card__kicker apm-mono apm-upper">{@kicker}</div>
            <% end %>
            <%= if @title do %>
              <div class="apm-card__title">{@title}</div>
            <% end %>
            <%= if @subtitle do %>
              <div class="apm-card__subtitle">{@subtitle}</div>
            <% end %>
          </div>
          <%= if @action != [] do %>
            <div class="apm-card__action">
              <%= render_slot(@action) %>
            </div>
          <% end %>
        </div>
      <% end %>
      <div class="apm-card__body">
        <%= render_slot(@inner_block) %>
      </div>
    </div>
    """
  end
end
