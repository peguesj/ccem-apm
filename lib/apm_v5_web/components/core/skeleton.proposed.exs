defmodule ApmV5Web.Components.Core.Skeleton do
  @moduledoc """
  Tier 1 primitive — SkeletonRows (loading placeholder).

  Sourced from design-intake/v11.0.0/from-designer/apm-data.jsx (SkeletonRows).
  Uses `.apm-shimmer` CSS keyframe (1.2s loop; static fill under prefers-reduced-motion).

  Each row: padding 9px 14px, border-bottom 1px solid var(--apm-border-subtle).
  Each cell: height 10px, border-radius 3px, flex 2 (first col) or 1 (rest),
  opacity decreasing by 0.08 per row (row 0 = opacity 1.0).

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-data.jsx → SkeletonRows
  - Motion spec: motion.md §Loading patterns
  """
  use Phoenix.Component

  attr :count, :integer, default: 8
  attr :cols, :integer, default: 5
  attr :rest, :global

  def skeleton_rows(assigns) do
    ~H"""
    <div class="apm-skeleton" {@rest}>
      <%= for i <- 0..(@count - 1) do %>
        <div class="apm-skeleton__row" style={"border-bottom:1px solid var(--apm-border-subtle);display:flex;gap:16px;padding:9px 14px"}>
          <%= for j <- 0..(@cols - 1) do %>
            <div
              class="apm-shimmer"
              style={"height:10px;border-radius:3px;flex:#{if j == 0, do: 2, else: 1};opacity:#{Float.round(1.0 - i * 0.08, 2)}"}
            />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
