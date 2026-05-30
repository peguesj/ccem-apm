defmodule ApmV5Web.Components.Data.Graph do
  @moduledoc """
  Tier 3 data-display — Graph (D3.js force-directed node/edge graph).

  Sourced from design-intake/v11.0.0/from-designer/apm-primitives.jsx
  (GraphNode + Edge components in DS Wave 2, CP-172).

  This is the ONE permitted JS island in the design system (component-map note).
  The entire graph is rendered by the GraphD3 hook — the server only provides
  structured data; the hook owns the SVG DOM. `phx-update="ignore"` is critical.

  Live edges have a 3s TTL pulse animation (`apm-edge-pulse` keyframe).
  Reduce-motion: static edges (no pulse).

  Node data shape: `%{id: String.t(), label: String.t(), status: String.t(),
    type: String.t(), x: float() | nil, y: float() | nil}`

  Edge data shape: `%{source: String.t(), target: String.t(), live: boolean(),
    edge_type: String.t()}` — `edge_type` added in CP-149 (testmaxxing wave 1).

  PubSub: LiveView subscribes to `"formation:graph"` topic and calls
  `push_event("graph_update", %{nodes: ..., edges: ...})` — hook handles diff.

  ## JS hook
  # TODO: colocate data/graph.hook.js — GraphD3 hook (D3 island, animated live edges,
  # PubSub 3s TTL). This is the ONE allowed JS island per component-map.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-primitives.jsx → GraphNode + Edge (DS Wave 2 CP-172)
  - Motion spec: motion.md §Loading patterns → Live edge (formation graph)
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :nodes, :list, default: []
  attr :edges, :list, default: []
  attr :height, :integer, default: 320
  attr :rest, :global

  slot :empty, required: true
  slot :loading, required: true
  slot :error, required: true

  def graph(assigns) do
    ~H"""
    <div
      id={@id}
      class="apm-graph"
      style={"min-height:#{@height}px;position:relative"}
      phx-hook="GraphD3"
      phx-update="ignore"
      data-nodes={Jason.encode!(@nodes)}
      data-edges={Jason.encode!(@edges)}
      data-height={@height}
      {@rest}
    >
      <%!-- GraphD3 hook manages SVG content. Slots below are rendered initially
           and replaced by the hook once D3 initializes. --%>
      <%= if @nodes == [] && @edges == [] do %>
        <%= render_slot(@empty) %>
      <% end %>
    </div>
    """
  end
end
