defmodule ApmWeb.Components.Feedback.Drawer do
  @moduledoc """
  Tier 4 feedback — Drawer (inspector panel / side drawer).

  Sourced from design-intake/v11.0.0/from-designer/apm-data.jsx (Drawer).

  Variants:
  - `inspector` (default): no backdrop, slides from right, sits alongside content.
  - `drawer`: with backdrop (bg oklch(0.1 0.01 255 / 0.5)), blocks main content.

  Panel: position absolute, top 0, right 0, bottom 0, width {width}px, zIndex 160,
    bg surface-raised, borderLeft 1px solid border-strong, boxShadow shadow-lg,
    display flex column,
    animation `apm-drawer-in var(--apm-dur-drawer) var(--apm-ease-drawer)` (slide-from-right 250ms).
  Body: class `apm-scroll`, flex 1, overflow auto, padding 16px.
  Footer: flex justify-end, gap 8, padding 12px 16px, borderTop border-subtle.

  Kicker: `apm-mono apm-upper`, fontSize 10, color text-dim, letterSpacing 0.1em.
  Title: fontSize 14, fontWeight 500.

  DrawerSlide hook handles:
  - Escape key → fires on_close event
  - Animation cleanup on remove

  ## JS hook
  # TODO: colocate feedback/drawer.hook.js — DrawerSlide hook (slide animation, esc key)
  # phx-hook="DrawerSlide" on the panel div.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-data.jsx → Drawer
  - Motion spec: motion.md §State-change animations → Drawer/inspector open
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :variant, :string, default: "inspector", values: ~w(inspector drawer)
  attr :width, :integer, default: 440
  attr :kicker, :string, default: nil
  attr :title, :string, default: nil
  attr :on_close, :string, default: nil
  attr :rest, :global

  slot :inner_block, required: true
  slot :footer

  def drawer(assigns) do
    ~H"""
    <div id={@id} class={["apm-drawer-container", "apm-drawer-container--#{@variant}"]} {@rest}>
      <%= if @variant == "drawer" do %>
        <div
          class="apm-drawer-backdrop"
          phx-click={@on_close}
          aria-hidden="true"
        />
      <% end %>
      <div
        id={"#{@id}-panel"}
        class="apm-drawer"
        style={"width:#{@width}px"}
        phx-hook="DrawerSlide"
        data-close-event={@on_close}
        role={if @variant == "drawer", do: "dialog", else: "complementary"}
        aria-label={@title || @kicker}
      >
        <div class="apm-drawer__header">
          <div class="apm-drawer__header-copy">
            <%= if @kicker do %>
              <div class="apm-drawer__kicker apm-mono apm-upper">{@kicker}</div>
            <% end %>
            <%= if @title do %>
              <div class="apm-drawer__title">{@title}</div>
            <% end %>
          </div>
          <button
            class="apm-drawer__close apm-focusable"
            type="button"
            aria-label="Close"
            phx-click={@on_close}
          >
            <svg
              width="15"
              height="15"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.8"
            >
              <path d="m6 6 12 12M18 6 6 18" />
            </svg>
          </button>
        </div>
        <div class="apm-drawer__body apm-scroll">
          {render_slot(@inner_block)}
        </div>
        <%= if @footer != [] do %>
          <div class="apm-drawer__footer">
            {render_slot(@footer)}
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
