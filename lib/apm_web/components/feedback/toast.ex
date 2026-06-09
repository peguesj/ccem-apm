defmodule ApmWeb.Components.Feedback.Toast do
  @moduledoc """
  Tier 4 feedback — Toast (auto-dismissing notification).

  Sourced from design-intake/v11.0.0/from-designer/apm-data.jsx (Toast).

  Container: display flex, alignItems flex-start, gap 10, padding 11px 13px,
    minWidth 280, maxWidth 360, bg surface-overlay,
    border 1px solid {tone.border}, borderLeft 3px solid {tone.fg},
    borderRadius r-md, boxShadow shadow-md.
  Animation: `apm-toast-in var(--apm-dur-base) var(--apm-ease-out)` (slide-up + fade-in 200ms;
    leave: slide-down + fade-out 150ms — motion.md §State-change animations).

  Icon selection (mirrors Toast JSX):
    success → check icon
    error   → x icon
    *       → bell icon

  Auto-dismiss: 4000ms. The Toast JS hook handles the timer and removal from DOM.
  `phx-remove` is set to trigger LiveView cleanup when the hook removes the element.

  Server helper: `ApmWeb.Components.Feedback.Toast.show/3` pushes a toast event
  via LiveView socket (to be implemented alongside the hook).

  ## JS hook
  # TODO: colocate feedback/toast.hook.js — Toast hook (auto-dismiss, slide-up/down animation)
  # phx-hook="Toast" — handles 4s timer + animation on mount/remove.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-data.jsx → Toast
  - Motion spec: motion.md §State-change animations → Toast
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr :id, :string, required: true

  attr :tone, :string,
    default: "success",
    values: ~w(success warning error info neutral)

  attr :title, :string, required: true
  attr :body, :string, default: nil
  attr :rest, :global

  def toast(assigns) do
    ~H"""
    <div
      id={@id}
      class={["apm-toast", "apm-toast--#{@tone}"]}
      phx-hook="Toast"
      role="alert"
      aria-live="polite"
      {@rest}
    >
      <span class="apm-toast__icon" aria-hidden="true">
        <%!-- Icon: success=check, error=x, *=bell (rendered by CSS or helper) --%>
        <%= case @tone do %>
          <% "success" -> %>
            <svg
              width="14"
              height="14"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
            >
              <path d="m5 12 5 5L20 6" />
            </svg>
          <% "error" -> %>
            <svg
              width="14"
              height="14"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
            >
              <path d="M6 6l12 12M18 6 6 18" />
            </svg>
          <% _ -> %>
            <svg
              width="14"
              height="14"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.6"
            >
              <path d="M6 8a6 6 0 0 1 12 0c0 7 3 8 3 8H3s3-1 3-8M10 21a2 2 0 0 0 4 0" />
            </svg>
        <% end %>
      </span>
      <div class="apm-toast__content">
        <div class="apm-toast__title">{@title}</div>
        <%= if @body do %>
          <div class="apm-toast__body">{@body}</div>
        <% end %>
      </div>
      <button
        class="apm-toast__close apm-focusable"
        aria-label="Dismiss"
        phx-click={JS.hide(to: "##{@id}")}
        type="button"
      >
        <svg
          width="13"
          height="13"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="1.8"
        >
          <path d="m6 6 12 12M18 6 6 18" />
        </svg>
      </button>
    </div>
    """
  end
end
