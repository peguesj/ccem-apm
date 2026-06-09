defmodule ApmWeb.Components.Feedback.ErrorInline do
  @moduledoc """
  Tier 4 feedback — ErrorInline (inline error display with optional retry).

  Sourced from design-intake/v11.0.0/from-designer/apm-data.jsx (ErrorInline).
  Used as the default `:error` slot content in all Tier-3 data components.

  Layout: flex column, alignItems center, justifyContent center,
    gap 10, padding 40px 24px, textAlign center.

  Icon container: width 40, height 40, borderRadius r-lg,
    bg status-error-soft, display flex center, color status-error.
  Heading: "Something went wrong", fontSize 14, fontWeight 500, color text-primary.
  Error message: class `apm-mono`, fontSize 11.5, color status-error, maxWidth 380.
  Retry button: only rendered when `retry` event is provided.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-data.jsx → ErrorInline
  """
  use Phoenix.Component

  attr :error, :string, required: true
  attr :retry, :string, default: nil
  attr :rest, :global

  def error_inline(assigns) do
    ~H"""
    <div class="apm-error-inline" role="alert" {@rest}>
      <div class="apm-error-inline__icon" aria-hidden="true">
        <svg
          width="20"
          height="20"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
        >
          <path d="M6 6l12 12M18 6 6 18" />
        </svg>
      </div>
      <div class="apm-error-inline__title">Something went wrong</div>
      <div class="apm-error-inline__message apm-mono">{@error}</div>
      <%= if @retry do %>
        <button
          class="apm-btn apm-btn--variant-secondary apm-btn--size-sm apm-focusable"
          type="button"
          phx-click={@retry}
        >
          Retry
        </button>
      <% end %>
    </div>
    """
  end
end
