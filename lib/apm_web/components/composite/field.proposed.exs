defmodule ApmWeb.Components.Composite.Field do
  @moduledoc """
  Tier 2 composite — Field (label + input + hint/error wrapper).

  Sourced from design-intake/v11.0.0/from-designer/apm-primitives.jsx (Field).

  Layout: flex column, gap 5px.
  Label: class `apm-upper`, fontSize 10, color var(--apm-text-dim), letterSpacing 0.08em,
  fontWeight 500. Required asterisk in var(--apm-status-error).
  Error text: fontSize 11, color var(--apm-status-error) — takes priority over hint.
  Hint text: fontSize 11, color var(--apm-text-faint).

  The `inner_block` slot renders the input/control (typically a `<.input>` Tier-1 primitive).

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-primitives.jsx → Field
  - Pseudo-state matrix: pseudo-states.md §Input / Field
  """
  use Phoenix.Component

  attr :label, :string, default: nil
  attr :hint, :string, default: nil
  attr :error, :string, default: nil
  attr :required, :boolean, default: false
  attr :rest, :global

  slot :inner_block, required: true

  def field(assigns) do
    ~H"""
    <div class="apm-field" {@rest}>
      <%= if @label do %>
        <label class="apm-field__label apm-upper">
          {@label}
          <%= if @required do %>
            <span class="apm-field__required" aria-hidden="true"> *</span>
          <% end %>
        </label>
      <% end %>
      <%= render_slot(@inner_block) %>
      <%= cond do %>
        <% @error -> %>
          <span class="apm-field__error" role="alert">{@error}</span>
        <% @hint -> %>
          <span class="apm-field__hint">{@hint}</span>
        <% true -> %>
      <% end %>
    </div>
    """
  end
end
