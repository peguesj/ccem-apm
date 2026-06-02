defmodule ApmWeb.Components.Templates.DetailPage do
  @moduledoc """
  Tier 5 template — DetailPage (header + tabs + scrollable body + footer).

  Sourced from design-intake/v11.0.0/from-designer/apm-shell.jsx.
  Used by: SessionLive, OrchestrationLive.

  Layout: flex column filling the content area:
    - header slot: PageHeader component (title, breadcrumb, badge, tabs, actions)
    - body slot: flex 1, overflow auto — primary content (JSONL viewer, DAG graph, etc.)
    - footer slot (optional): fixed-height action bar at bottom

  The `:header` slot typically wraps a `<.page_header>` composite.
  The `:body` slot renders the active tab content.
  The `:footer` slot renders action buttons (approve/deny, export, etc.).

  Page enter animation: 8px slide-up, 200ms ease-out, transform only
  (visibility rule: opacity-gated reveals forbidden at page level — motion.md).

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md — DetailPage
  - JSX source: apm-shell.jsx — Session/Orchestration screens
  - Motion spec: motion.md §State-change animations → Page enter
  """
  use Phoenix.Component

  attr :rest, :global

  slot :header, required: true
  slot :body, required: true
  slot :footer

  def detail_page(assigns) do
    ~H"""
    <div class="apm-detail-page apm-page-enter" {@rest}>
      <div class="apm-detail-page__header">
        <%= render_slot(@header) %>
      </div>
      <div class="apm-detail-page__body apm-scroll">
        <%= render_slot(@body) %>
      </div>
      <%= if @footer != [] do %>
        <div class="apm-detail-page__footer">
          <%= render_slot(@footer) %>
        </div>
      <% end %>
    </div>
    """
  end
end
