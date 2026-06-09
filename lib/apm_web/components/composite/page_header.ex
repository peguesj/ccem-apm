defmodule ApmWeb.Components.Composite.PageHeader do
  @moduledoc """
  Tier 2 composite — PageHeader (title bar with breadcrumb, badge, tabs).

  Sourced from design-intake/v11.0.0/from-designer/apm-shell.jsx (PageHeader).

  Layout: padding 14px 20px 0, borderBottom 1px solid var(--apm-border-subtle)
    (omitted when tabs are present — tabs own the bottom border).

  Title row: h1 fontSize 18, fontWeight 500, letterSpacing -0.02em, margin 0.
  Breadcrumb: `apm-mono`, fontSize 12, color text-muted, preceded by "/" separator.
  Actions: marginLeft auto, flex, gap 8 (renders the `:actions` slot).

  Tabs (rendered when `tabs` is non-empty):
    flex row, gap 2, marginTop 12.
    Each tab button (class `apm-focusable`):
      padding 7px 12px, fontSize 12.5, fontWeight 500, bg none, border 0.
      active → borderBottom 2px solid var(--apm-accent), color text-primary.
      default → borderBottom 2px solid transparent, color text-dim.
      marginBottom -1px (flush to container border).

  `tabs` is a list of maps with `id` and `label` keys.
  `active_tab` is the currently selected tab id.
  Wire `phx-click` + `phx-value-id` on tab buttons for LiveView.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-shell.jsx → PageHeader
  - Pseudo-state matrix: pseudo-states.md §Tab
  """
  use Phoenix.Component

  attr :title, :string, required: true
  attr :breadcrumb, :string, default: nil
  attr :tabs, :list, default: []
  attr :active_tab, :string, default: nil
  attr :on_tab, :string, default: nil
  attr :rest, :global

  slot :badge
  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class={["apm-page-header", @tabs != [] && "apm-page-header--has-tabs"]} {@rest}>
      <div class="apm-page-header__title-row">
        <h1 class="apm-page-header__title">{@title}</h1>
        <%= if @breadcrumb do %>
          <span class="apm-page-header__sep" aria-hidden="true">/</span>
          <span class="apm-page-header__breadcrumb apm-mono">{@breadcrumb}</span>
        <% end %>
        <%= if @badge != [] do %>
          <span class="apm-page-header__badge">
            {render_slot(@badge)}
          </span>
        <% end %>
        <%= if @actions != [] do %>
          <div class="apm-page-header__actions">
            {render_slot(@actions)}
          </div>
        <% end %>
      </div>
      <%= if @tabs != [] do %>
        <div class="apm-page-header__tabs" role="tablist">
          <%= for tab <- @tabs do %>
            <button
              class={[
                "apm-page-header__tab",
                "apm-focusable",
                @active_tab == tab.id && "apm-page-header__tab--active"
              ]}
              type="button"
              role="tab"
              aria-selected={to_string(@active_tab == tab.id)}
              phx-click={@on_tab}
              phx-value-id={tab.id}
            >
              {tab.label}
            </button>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
