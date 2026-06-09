defmodule ApmWeb.Components.Templates.QueuePage do
  @moduledoc """
  Tier 5 template — QueuePage (filter rail + list + inspector layout).

  Sourced from design-intake/v11.0.0/from-designer/apm-shell.jsx.
  Used by: PendingLive, AuditLive.

  Layout: three-column flex row filling the content area:
    - filter_rail (left, ~200px, fixed): filter controls, status counts, policy badges
    - list (center, flex 1): scrollable list of decision/audit cards; SwipeCard or DataTable
    - inspector (right, ~360px, optional): detail panel for selected item (Drawer variant=inspector)

  The inspector is conditionally shown when `selected_id` is set.
  `show_inspector` collapses/expands without removing from DOM (preserves scroll state).

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md — QueuePage (Decide/Pending layout)
  - JSX source: apm-shell.jsx — Decide section screens
  """
  use Phoenix.Component

  attr :selected_id, :string, default: nil
  attr :show_inspector, :boolean, default: false
  attr :rest, :global

  slot :filter_rail, required: true
  slot :list, required: true
  slot :inspector

  def queue_page(assigns) do
    ~H"""
    <div class="apm-queue-page" {@rest}>
      <div class="apm-queue-page__filter-rail">
        {render_slot(@filter_rail)}
      </div>
      <div class="apm-queue-page__list">
        {render_slot(@list)}
      </div>
      <%= if @show_inspector && @inspector != [] do %>
        <div class="apm-queue-page__inspector">
          {render_slot(@inspector)}
        </div>
      <% end %>
    </div>
    """
  end
end
