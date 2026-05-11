defmodule ApmV5Web.Components.PageLayout do
  @moduledoc """
  Three-zone CCEM page layout shell: sidebar + main + inspector.

  Used as the outer wrapper in redesigned LiveViews. The layout fills the full
  viewport using a horizontal flex row. The sidebar zone collapses to a 48px
  icon rail when `sidebar_collapsed` is true. The right inspector zone renders
  only when both `inspector_open` and an `inspector` slot are provided.

  ## Usage

      <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
        <:sidebar>
          <.sidebar_nav ... />
        </:sidebar>
        <:topbar>
          <.top_bar ... />
        </:topbar>
        <:main>
          <p>Main content</p>
        </:main>
        <:inspector>
          <.inspector_panel mode="copilot" open={true} />
        </:inspector>
      </.page_layout>
  """

  use Phoenix.Component

  # ---------------------------------------------------------------------------
  # page_layout/1
  # ---------------------------------------------------------------------------

  @doc """
  Renders the full-viewport three-zone CCEM page layout shell.

  ## Attributes

  - `sidebar_collapsed` — when `true`, sidebar collapses to a 48px icon rail (default: `false`)
  - `inspector_open`    — when `true` and an `inspector` slot is provided, the right inspector
    panel is rendered (default: `false`)
  - `inspector_mode`    — mode string forwarded to inspector context; informational only here
    (default: `"copilot"`)
  - `class`             — additional CSS classes applied to the outer wrapper element
  - `rest`              — any additional HTML attributes forwarded to the root `<div>`

  ## Slots

  - `sidebar`   (required) — left sidebar nav content
  - `topbar`               — optional top bar row; rendered as a 48px-shrink strip above main
  - `main`      (required) — primary content area; fills remaining space with scroll
  - `inspector`            — right inspector panel content; shown only when `inspector_open`
    is `true` and this slot is provided
  """

  attr :sidebar_collapsed, :boolean, default: false
  attr :inspector_open, :boolean, default: false
  attr :inspector_mode, :string, default: "copilot"
  attr :class, :string, default: nil
  attr :rest, :global

  slot :sidebar, required: true
  slot :topbar
  slot :main, required: true
  slot :inspector

  @spec page_layout(map()) :: Phoenix.LiveView.Rendered.t()
  def page_layout(assigns) do
    assigns = assign(assigns, :sidebar_width, if(assigns.sidebar_collapsed, do: 48, else: 220))

    ~H"""
    <div
      style={
        "display:flex; height:100vh; overflow:hidden; " <>
          "background:var(--ccem-bg-0); " <>
          "font-family:var(--ccem-font-sans); " <>
          "color:var(--ccem-fg);"
      }
      class={@class}
      {@rest}
    >
      <%!-- Sidebar zone --%>
      <div
        id="ccem-sidebar"
        style={
          "width:#{@sidebar_width}px; flex-shrink:0; " <>
            "transition:width var(--ccem-dur-base,150ms) var(--ccem-ease-out,ease-out); " <>
            "overflow:hidden; " <>
            "border-right:1px solid var(--ccem-line-subtle);"
        }
      >
        {render_slot(@sidebar)}
      </div>

      <%!-- Center column: topbar + main --%>
      <div style="flex:1; display:flex; flex-direction:column; min-width:0; overflow:hidden;">
        <%= if @topbar != [] do %>
          <div style="flex-shrink:0; border-bottom:1px solid var(--ccem-line-subtle);">
            {render_slot(@topbar)}
          </div>
        <% end %>
        <div style="flex:1; overflow:auto; padding:var(--ccem-s-4,16px);">
          {render_slot(@main)}
        </div>
      </div>

      <%!-- Right inspector zone --%>
      <%= if @inspector_open and @inspector != [] do %>
        <div style="width:280px; flex-shrink:0; border-left:1px solid var(--ccem-line-subtle); overflow:hidden;">
          {render_slot(@inspector)}
        </div>
      <% end %>
    </div>
    """
  end
end
