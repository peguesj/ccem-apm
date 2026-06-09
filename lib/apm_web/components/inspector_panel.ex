defmodule ApmWeb.Components.InspectorPanel do
  @moduledoc """
  Right-side contextual inspector panel. Collapsible.
  Switches context based on the `mode` assign.

  ## Usage

      <.inspector_panel mode="copilot" open={true} on_close="close_inspector">
        <:copilot>
          <p>AI co-pilot content here</p>
        </:copilot>
        <:selection>
          <p>Selection details here</p>
        </:selection>
        <:filters>
          <p>Filter controls here</p>
        </:filters>
      </.inspector_panel>

  ## Modes
  - `"selection"` — shows contextual detail for the currently selected item
  - `"copilot"`   — AI assistant panel (default)
  - `"filters"`   — filter/search controls
  """

  use Phoenix.Component

  # ---------------------------------------------------------------------------
  # inspector_panel/1
  # ---------------------------------------------------------------------------

  @doc """
  Renders the right-side inspector panel.

  ## Attributes
  - `mode`     — active tab: `"selection"`, `"copilot"`, or `"filters"` (default: `"copilot"`)
  - `open`     — whether the panel is visible (default: `true`)
  - `width`    — panel width in pixels (default: `280`)
  - `on_close` — phx-click event name fired when the close button is pressed (default: `nil`)
  - `class`    — additional CSS classes applied to the outer container (default: `nil`)

  ## Slots
  - `selection` — content rendered when `mode="selection"`
  - `copilot`   — content rendered when `mode="copilot"`
  - `filters`   — content rendered when `mode="filters"`
  """
  attr :mode, :string, default: "copilot"
  attr :open, :boolean, default: true
  attr :width, :integer, default: 280
  attr :on_close, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global

  slot :selection
  slot :copilot
  slot :filters

  def inspector_panel(%{open: false} = assigns) do
    ~H"""
    <div style="display:none"></div>
    """
  end

  def inspector_panel(assigns) do
    ~H"""
    <div
      class={@class}
      style={"width: #{@width}px; flex-shrink: 0; background: var(--ccem-bg-1); border-left: 1px solid var(--ccem-line-subtle); display: flex; flex-direction: column; height: 100%;"}
      {@rest}
    >
      <!-- Header: 40px -->
      <div style="padding: 0 12px; height: 40px; display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid var(--ccem-line-subtle);">
        <span style="font-size: 13px; font-weight: 600; color: var(--ccem-fg); letter-spacing: 0.01em;">
          Inspector
        </span>
        <button
          phx-click={@on_close}
          style="display: flex; align-items: center; justify-content: center; width: 24px; height: 24px; background: transparent; border: none; border-radius: 4px; color: var(--ccem-fg-dim); cursor: pointer; font-size: 14px; line-height: 1;"
        >
          ✕
        </button>
      </div>
      <!-- Mode tabs: 32px -->
      <div style="display: flex; height: 32px; border-bottom: 1px solid var(--ccem-line-subtle);">
        <button
          style={tab_style(@mode == "selection")}
          phx-click="inspector_mode"
          phx-value-mode="selection"
        >
          Selection
        </button>
        <button
          style={tab_style(@mode == "copilot")}
          phx-click="inspector_mode"
          phx-value-mode="copilot"
        >
          AI
        </button>
        <button
          style={tab_style(@mode == "filters")}
          phx-click="inspector_mode"
          phx-value-mode="filters"
        >
          Filters
        </button>
      </div>
      <!-- Content: flex-1, scrollable -->
      <div style="flex: 1; overflow-y: auto; padding: 12px;">
        <%= case @mode do %>
          <% "selection" -> %>
            {render_slot(@selection)}
          <% "copilot" -> %>
            {render_slot(@copilot)}
          <% "filters" -> %>
            {render_slot(@filters)}
          <% _ -> %>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec tab_style(boolean()) :: String.t()
  defp tab_style(true) do
    "flex: 1; height: 100%; border: none; border-bottom: 2px solid var(--ccem-iris); " <>
      "color: var(--ccem-fg); background: var(--ccem-iris-soft); " <>
      "font-size: 11px; font-weight: 600; cursor: pointer; padding: 0 8px;"
  end

  defp tab_style(false) do
    "flex: 1; height: 100%; border: none; border-bottom: 2px solid transparent; " <>
      "color: var(--ccem-fg-dim); background: transparent; " <>
      "font-size: 11px; font-weight: 500; cursor: pointer; padding: 0 8px;"
  end
end
