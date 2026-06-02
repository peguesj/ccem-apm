defmodule ApmWeb.Components.Data.LoadingScreen do
  @moduledoc """
  Tier 3 data-display — LoadingScreen (Lottie wireframe-block / CSS stand-in).

  Sourced from design-intake/v11.0.0/from-designer/apm-data.jsx (WireframeBlock).

  Production: LottieLoader hook plays the appropriate `.json` from `assets/lottie/`:
    block → wireframe-block.json  (header bar + paragraph blocks)
    table → wireframe-table.json  (row stack)
    graph → wireframe-graph.json  (node/edge skeleton)

  The hook plays once on mount and fades the container out (200ms ease-out) when
  `data-loaded` flips to `"true"`. Engineer vendors `lottie-web` at Phase 2.

  CSS stand-in: absolutely positioned divs with `apm-wf-breathe` keyframe
  (1.4s ease-out infinite, animationDelay 100ms * block index). Provides correct
  layout geometry so timing/layout is pinned before Lottie `.json` is produced.

  Reduce-motion: static gray skeleton, no breathe animation (apm-tokens.css).

  `loaded` attr flips `data-loaded` to signal the hook to fade out.

  ## JS hook
  # TODO: colocate data/loading_screen.hook.js — LottieLoader hook
  # phx-hook="LottieLoader" — reads data-variant, plays lottie once, fades on data-loaded.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-data.jsx → WireframeBlock
  - Motion spec: motion.md §Loading patterns → Full-page initial load (Lottie wireframe-block)
  """
  use Phoenix.Component

  attr :variant, :string, default: "block", values: ~w(block table graph)
  attr :loaded, :boolean, default: false
  attr :id, :string, default: nil
  attr :rest, :global

  def loading_screen(assigns) do
    ~H"""
    <div
      id={@id}
      class={["apm-loading-screen", "apm-loading-screen--#{@variant}"]}
      phx-hook="LottieLoader"
      data-variant={@variant}
      data-loaded={to_string(@loaded)}
      style={"opacity:#{if @loaded, do: 0, else: 1};transition:opacity var(--apm-dur-base) var(--apm-ease-out)"}
      aria-busy={to_string(!@loaded)}
      aria-label="Loading…"
      {@rest}
    >
      <%!-- CSS wireframe stand-in blocks (replaced by Lottie at Phase 2). --%>
      <%= for {block, i} <- Enum.with_index(wf_blocks(@variant)) do %>
        <div
          class="apm-wf-block"
          style={"position:absolute;left:#{block.x};top:#{block.y}px;width:#{block.w};height:#{block.h}px;background:var(--apm-surface-overlay);border-radius:var(--apm-r-md);animation:apm-wf-breathe 1.4s var(--apm-ease-out) infinite;animation-delay:#{i * 100}ms"}
        />
      <% end %>
    </div>
    """
  end

  defp wf_blocks("table") do
    Enum.map(0..6, fn i -> %{x: "24px", y: 24 + i * 30, w: "calc(100% - 48px)", h: 18} end)
  end

  defp wf_blocks("graph") do
    [
      %{x: "42%", y: 30, w: "90px", h: 36},
      %{x: "18%", y: 120, w: "80px", h: 30},
      %{x: "42%", y: 120, w: "80px", h: 30},
      %{x: "66%", y: 120, w: "80px", h: 30},
      %{x: "30%", y: 210, w: "64px", h: 26},
      %{x: "54%", y: 210, w: "64px", h: 26}
    ]
  end

  defp wf_blocks(_block) do
    [
      %{x: "24px", y: 24, w: "40%", h: 26},
      %{x: "24px", y: 64, w: "calc(100% - 48px)", h: 70},
      %{x: "24px", y: 148, w: "30%", h: 18},
      %{x: "24px", y: 178, w: "calc(100% - 48px)", h: 90}
    ]
  end
end
