defmodule ApmWeb.Components.Core.Input do
  @moduledoc """
  Tier 1 primitive — Input (text field).

  Sourced from design-intake/v11.0.0/from-designer/apm-primitives.jsx (Input).
  Focus ring via `.apm-focusable` — 2px accent ring at 2px offset (pseudo-states.md).

  State classes (CSS handles transitions at 120ms var(--apm-ease-out)):
  - default: bg surface-raised, border border-default
  - focus: border accent, box-shadow 0 0 0 2px var(--apm-accent-glow)
  - disabled: bg surface-base @50%, border border-default
  - error: border status-error (error text rendered by Field component)

  `mono` switches font to var(--apm-font-mono). `icon` slot renders a leading icon
  in text-dim color. `suffix` slot renders trailing content (e.g. a Kbd chip).

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-primitives.jsx → Input
  - Pseudo-state matrix: pseudo-states.md §Input / Field
  """
  use Phoenix.Component

  attr :id, :string, default: nil
  attr :name, :string, default: nil
  attr :value, :string, default: nil
  attr :placeholder, :string, default: nil
  attr :error, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :mono, :boolean, default: false
  attr :auto_focus, :boolean, default: false
  attr :rest, :global, include: ~w(autocomplete form inputmode type)

  slot :icon
  slot :suffix

  def input(assigns) do
    ~H"""
    <div class={[
      "apm-input-wrap",
      @error && "apm-input-wrap--error",
      @disabled && "apm-input-wrap--disabled",
      "apm-focusable"
    ]}>
      <%= if @icon != [] do %>
        <span class="apm-input__icon" aria-hidden="true">
          <%= render_slot(@icon) %>
        </span>
      <% end %>
      <input
        id={@id}
        name={@name}
        value={@value}
        placeholder={@placeholder}
        disabled={@disabled}
        autofocus={@auto_focus}
        class={[
          "apm-input__field",
          @mono && "apm-mono"
        ]}
        {@rest}
      />
      <%= if @suffix != [] do %>
        <span class="apm-input__suffix">
          <%= render_slot(@suffix) %>
        </span>
      <% end %>
    </div>
    """
  end
end
