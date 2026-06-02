defmodule ApmWeb.Components.Templates.SplitView do
  @moduledoc """
  Tier 5 template — SplitView (master list + detail panel, resizable).

  Sourced from design-intake/v11.0.0/from-designer/apm-shell.jsx.
  Used by: FleetLive, MemoryLive, IntegrationsLive.

  Layout: flex row, height 100%, overflow hidden.
    - master (left): fixed or flex width, overflow auto, borderRight 1px solid border-subtle.
      Contains searchable list (agents, observations, integrations).
    - detail (right): flex 1, overflow hidden.
      Contains inspector content for the selected master item.

  `master_width` controls the left panel width (default 300px).
  When no item is selected, `detail` renders the `:empty_detail` slot.

  The master column typically contains a SearchBox + DataTable or a
  custom list (AgentCard grid in FleetLive).

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md — SplitView
  - JSX source: apm-shell.jsx — Fleet/Memory/Integrations screens
  """
  use Phoenix.Component

  attr :master_width, :integer, default: 300
  attr :selected_id, :any, default: nil
  attr :rest, :global

  slot :master, required: true
  slot :detail, required: true
  slot :empty_detail

  def split_view(assigns) do
    ~H"""
    <div class="apm-split-view" {@rest}>
      <div
        class="apm-split-view__master apm-scroll"
        style={"width:#{@master_width}px;flex-shrink:0"}
      >
        <%= render_slot(@master) %>
      </div>
      <div class="apm-split-view__detail">
        <%= if @selected_id do %>
          <%= render_slot(@detail) %>
        <% else %>
          <%= if @empty_detail != [] do %>
            <%= render_slot(@empty_detail) %>
          <% else %>
            <div class="apm-split-view__empty-detail">
              <ApmWeb.Components.Feedback.EmptyState.empty_state
                icon="agent"
                title="Select an item"
                body="Choose an item from the list to view details."
              />
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end
end
