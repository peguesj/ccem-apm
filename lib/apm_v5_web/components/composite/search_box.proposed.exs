defmodule ApmV5Web.Components.Composite.SearchBox do
  @moduledoc """
  Tier 2 composite — SearchBox (Input + search icon + Kbd hint).

  Sourced from design-intake/v11.0.0/from-designer/apm-primitives.jsx
  (Input + I.search icon, used in Topbar and DataTable filter contexts).

  Extends the Tier-1 Input with a pre-wired leading search icon and optional
  trailing Kbd chip. Focus ring via `.apm-focusable` (2px accent ring).

  `phx-debounce` is passed through the `rest` global attr — callers should
  set phx-debounce="200" for live filtering use cases.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-primitives.jsx → Input + I.search usage in Topbar/CommandPalette
  """
  use Phoenix.Component

  attr :id, :string, default: nil
  attr :name, :string, default: nil
  attr :value, :string, default: nil
  attr :placeholder, :string, default: "Search…"
  attr :kbd_hint, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :rest, :global, include: ~w(phx-change phx-debounce phx-keyup autocomplete)

  def search_box(assigns) do
    ~H"""
    <div class={["apm-search-box", @disabled && "apm-search-box--disabled", "apm-focusable"]}>
      <span class="apm-search-box__icon" aria-hidden="true">
        <%!-- I.search SVG: circle cx=11 cy=11 r=7, path "m20 20-3.5-3.5" --%>
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6">
          <circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>
        </svg>
      </span>
      <input
        id={@id}
        name={@name}
        value={@value}
        placeholder={@placeholder}
        disabled={@disabled}
        type="search"
        class="apm-search-box__input"
        {@rest}
      />
      <%= if @kbd_hint do %>
        <span class="apm-search-box__kbd apm-kbd apm-mono">{@kbd_hint}</span>
      <% end %>
    </div>
    """
  end
end
