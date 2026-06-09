defmodule ApmWeb.Components.Composite.StatTile do
  @moduledoc """
  Tier 2 composite — StatTile (metric tile with optional sparkline).

  Sourced from design-intake/v11.0.0/from-designer/apm-primitives.jsx (StatTile + useCountUp).

  Layout: flex column, gap 6, padding 12px 14px, bg surface-raised, border border-subtle,
  borderRadius r-lg, minWidth 110, flex 1.

  Label: class `apm-upper`, fontSize 9.5, color text-dim, letterSpacing 0.1em, fontWeight 500.
  Value: class `apm-tabular`, fontSize 24, fontWeight 500, letterSpacing -0.03em,
    fontFamily mono when `mono` is true (default true).
  Unit: fontSize 11, color text-dim.
  Delta: rendered as a Badge with `delta_tone`.

  `count_up` enables the CountUp JS hook (400ms ease-out, reduce-motion-aware snap).
  `spark` slot renders a Tier-3 Sparkline below the value row.

  ## JS hook
  # TODO: colocate composite/stat_tile.hook.js — CountUp hook (CP-310 reference)
  # phx-hook="CountUp" on the value span when count_up is true.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-primitives.jsx → StatTile, useCountUp
  - Motion spec: motion.md §Advanced micro-interactions → Token-count tickup
  """
  use Phoenix.Component

  # Phase 2 cross-component import convention: explicit import of each used
  # subcomponent. Alias or import at module scope for all components this
  # composite depends on so callers get a clean API without full module paths.
  import ApmWeb.Components.Core.Badge, only: [badge: 1]

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :unit, :string, default: nil
  attr :delta, :string, default: nil

  attr :delta_tone, :string,
    default: "success",
    values: ~w(success warning error info neutral)

  attr :mono, :boolean, default: true
  attr :count_up, :boolean, default: false
  attr :rest, :global

  slot :spark

  def stat_tile(assigns) do
    ~H"""
    <div class="apm-stat-tile" {@rest}>
      <div class="apm-stat-tile__label apm-upper">{@label}</div>
      <div class="apm-stat-tile__value-row">
        <span
          class={["apm-stat-tile__value apm-tabular", @mono && "apm-mono"]}
          phx-hook={if @count_up, do: "CountUp", else: nil}
          data-target={if @count_up, do: @value, else: nil}
          id={if @count_up, do: "stat-#{:erlang.phash2(@label)}", else: nil}
        >
          {@value}
        </span>
        <%= if @unit do %>
          <span class="apm-stat-tile__unit">{@unit}</span>
        <% end %>
        <%= if @delta do %>
          <.badge tone={@delta_tone}>{@delta}</.badge>
        <% end %>
      </div>
      <%= if @spark != [] do %>
        <div class="apm-stat-tile__spark">
          {render_slot(@spark)}
        </div>
      <% end %>
    </div>
    """
  end
end
