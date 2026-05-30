defmodule ApmV5Web.Components.Feedback.SwipeCard do
  @moduledoc """
  Tier 4 feedback — SwipeCard (approval card with swipe-to-decide gesture).

  Sourced from design-intake/v11.0.0/from-designer handoff (Decide queue).
  Used by PendingLive and AuditLive via the QueuePage template.

  Gesture spec (motion.md §Advanced micro-interactions → Approval card swipe):
    - Drag left  → deny  (fires `swipe_decide` with `decision: "deny"`)
    - Drag right → allow (fires `swipe_decide` with `decision: "allow"`)
    - Rubber-band at 0.85× past 140px threshold
    - Commits past ±110px
    - Snap-back 200ms ease-out if below threshold
  Reduce-motion: drag still works; no rubber-band easing.

  The SwipeDecide hook drives all gesture handling via pointer events.
  `phx-update="ignore"` prevents LiveView from resetting card transform during swipe.

  Card content is provided via the `inner_block` slot (typically approval details:
  tool name, agent id, countdown ring, policy badges).

  `decision_id` is passed back with the swipe event so the LiveView can identify
  which pending decision was acted on.

  ## JS hook
  # TODO: colocate feedback/swipe_card.hook.js — SwipeDecide hook
  # (pointer drag, rubber-band, commit at ±110px, snap-back 200ms ease-out)

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - Motion spec: motion.md §Advanced micro-interactions → Approval card swipe
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :decision_id, :string, required: true
  attr :on_decide, :string, default: "swipe_decide"
  attr :rest, :global

  slot :inner_block, required: true

  def swipe_card(assigns) do
    ~H"""
    <div
      id={@id}
      class="apm-swipe-card"
      phx-hook="SwipeDecide"
      phx-update="ignore"
      data-decision-id={@decision_id}
      data-decide-event={@on_decide}
      role="article"
      aria-label="Swipe right to allow, left to deny"
      {@rest}
    >
      <%!-- Deny indicator (revealed on left swipe) --%>
      <div class="apm-swipe-card__indicator apm-swipe-card__indicator--deny" aria-hidden="true">
        <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M6 6l12 12M18 6 6 18"/></svg>
        Deny
      </div>
      <%!-- Allow indicator (revealed on right swipe) --%>
      <div class="apm-swipe-card__indicator apm-swipe-card__indicator--allow" aria-hidden="true">
        <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="m5 12 5 5L20 6"/></svg>
        Allow
      </div>
      <%!-- Card face --%>
      <div class="apm-swipe-card__face">
        <%= render_slot(@inner_block) %>
      </div>
      <%!-- Accessible fallback buttons --%>
      <div class="apm-swipe-card__buttons" aria-label="Decision buttons">
        <button
          class="apm-btn apm-btn--variant-danger apm-btn--size-sm apm-focusable"
          type="button"
          phx-click={@on_decide}
          phx-value-decision="deny"
          phx-value-id={@decision_id}
        >Deny</button>
        <button
          class="apm-btn apm-btn--variant-primary apm-btn--size-sm apm-focusable"
          type="button"
          phx-click={@on_decide}
          phx-value-decision="allow"
          phx-value-id={@decision_id}
        >Allow</button>
      </div>
    </div>
    """
  end
end
