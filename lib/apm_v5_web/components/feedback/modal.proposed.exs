defmodule ApmV5Web.Components.Feedback.Modal do
  @moduledoc """
  Tier 4 feedback — Modal (dialog overlay with focus trap).

  Sourced from design-intake/v11.0.0/from-designer/apm-data.jsx (Modal).

  Backdrop: fixed inset 0, zIndex 200, bg oklch(0.1 0.01 255 / 0.6),
    animation `apm-backdrop-in var(--apm-dur-base) ease`.
  Dialog: width {width}px, maxWidth 90%, maxHeight 85%, overflow auto,
    bg surface-raised, border 1px solid border-strong, borderRadius r-xl,
    boxShadow shadow-lg,
    animation `apm-modal-enter var(--apm-dur-base) var(--apm-ease-out)`
    (scale 0.96→1.0 + backdrop fade 200ms).
  Leave: scale 1.0→0.98 + backdrop fade-out 150ms.

  Kicker: `apm-mono apm-upper`, fontSize 10, color text-dim, letterSpacing 0.1em.
  Title: fontSize 16, fontWeight 500, letterSpacing -0.02em.
  Footer: flex justify-end, gap 8, padding 12px 18px, borderTop border-subtle.

  The ModalTrap hook handles:
  - Escape key → fires phx-click on the close button
  - Focus trap: Tab cycles within the dialog

  ## JS hook
  # TODO: colocate feedback/modal.hook.js — ModalTrap hook (esc, focus-trap)
  # phx-hook="ModalTrap" on the dialog element.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-data.jsx → Modal
  - Motion spec: motion.md §State-change animations → Modal enter/leave
  """
  use Phoenix.Component

  import Phoenix.LiveView.JS, only: [hide: 1]

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :kicker, :string, default: nil
  attr :width, :integer, default: 480
  attr :on_close, :string, default: nil
  attr :rest, :global

  slot :inner_block, required: true
  slot :footer

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class="apm-modal-backdrop"
      phx-click={@on_close && JS.dispatch("modal:close", to: "##{@id}-dialog")}
      aria-modal="true"
      role="dialog"
      {@rest}
    >
      <div
        id={"#{@id}-dialog"}
        class="apm-modal"
        style={"width:#{@width}px"}
        phx-hook="ModalTrap"
        phx-click-away={@on_close}
        data-close-event={@on_close}
      >
        <div class="apm-modal__header">
          <div class="apm-modal__header-copy">
            <%= if @kicker do %>
              <div class="apm-modal__kicker apm-mono apm-upper">{@kicker}</div>
            <% end %>
            <div class="apm-modal__title">{@title}</div>
          </div>
          <button
            class="apm-modal__close apm-focusable"
            type="button"
            aria-label="Close"
            phx-click={@on_close}
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="m6 6 12 12M18 6 6 18"/></svg>
          </button>
        </div>
        <div class="apm-modal__body">
          <%= render_slot(@inner_block) %>
        </div>
        <%= if @footer != [] do %>
          <div class="apm-modal__footer">
            <%= render_slot(@footer) %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
