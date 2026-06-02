defmodule ApmWeb.Components.GraphComponents do
  @moduledoc """
  SVG components for D3.js force-layout dependency graphs.

  These are server-side Phoenix function components that render SVG elements.
  The D3.js layout engine runs in JavaScript via the existing GraphForce hook,
  which manages x/y positioning via data attributes. These templates are
  responsible for rendering the SVG structure and visual styling only.

  ## Usage

      import ApmWeb.Components.GraphComponents

      <.graph_node node_id="agent-1" label="Orchestrator" role="orchestrator" status="active" />
      <.graph_edge edge_id="e1" source_id="agent-1" target_id="agent-2" edge_type="pubsub" live />
  """

  use Phoenix.Component

  # ---------------------------------------------------------------------------
  # graph_node/1
  # ---------------------------------------------------------------------------

  @doc """
  Renders an SVG `<g>` group element representing an agent node in a D3.js
  force-layout graph. The D3.js GraphForce hook manages positioning by applying
  a `transform` attribute to the group.

  ## Attributes

  - `node_id` - Unique identifier; written as `data-node-id` for D3.js selection
  - `label` - Display label; truncated to 12 characters
  - `role` - Agent role: `orchestrator`, `squadron_lead`, `swarm_agent`,
    `cluster_agent`, or `individual`
  - `status` - Agent status: `active`, `idle`, `error`, or `complete`
  - `size` - Diameter in pixels (default 36); radius = size / 2
  - `class` - Additional CSS classes
  - `rest` - Any additional HTML/SVG attributes passed through

  ## Example

      <.graph_node node_id="orch-1" label="Formation Lead" role="orchestrator" status="active" />
  """
  attr :node_id, :string, required: true
  attr :label, :string, required: true
  attr :role, :string, default: "individual"
  attr :status, :string, default: "idle"
  attr :size, :integer, default: 36
  attr :class, :string, default: nil
  attr :rest, :global

  def graph_node(assigns) do
    ~H"""
    <g
      data-node-id={@node_id}
      class={[@class]}
      {@rest}
    >
      <%!-- outer status ring --%>
      <circle
        r={div(@size, 2) + 3}
        fill="none"
        stroke={status_color(@status)}
        stroke-width="2"
        class={status_class(@status)}
      />
      <%!-- body --%>
      <circle r={div(@size, 2)} fill={role_color(@role)} />
      <%!-- label below --%>
      <text
        y={div(@size, 2) + 14}
        text-anchor="middle"
        font-size="10"
        fill="oklch(0.78 0.012 255)"
        font-family="var(--ccem-font-mono)"
      >
        {truncate_label(@label, 12)}
      </text>
    </g>
    """
  end

  # ---------------------------------------------------------------------------
  # graph_edge/1
  # ---------------------------------------------------------------------------

  @doc """
  Renders an SVG `<line>` element representing a directed edge between two
  agent nodes in a D3.js force-layout graph. The D3.js GraphForce hook updates
  `x1`, `y1`, `x2`, and `y2` attributes on each tick using the `data-source`
  and `data-target` identifiers.

  ## Attributes

  - `edge_id` - Unique identifier; written as `data-edge-id` for D3.js selection
  - `source_id` - `node_id` of the source node; written as `data-source`
  - `target_id` - `node_id` of the target node; written as `data-target`
  - `edge_type` - Visual style: `pubsub`, `dependency`, `data_flow`, or `default`
  - `live` - When `true`, adds `ccem-pulse` animation class and 2px stroke width
  - `class` - Additional CSS classes
  - `rest` - Any additional HTML/SVG attributes passed through

  ## Example

      <.graph_edge edge_id="e-1-2" source_id="agent-1" target_id="agent-2"
                   edge_type="pubsub" live={@active} />
  """
  attr :edge_id, :string, required: true
  attr :source_id, :string, required: true
  attr :target_id, :string, required: true
  attr :edge_type, :string, default: "default"
  attr :live, :boolean, default: false
  attr :class, :string, default: nil
  attr :rest, :global

  def graph_edge(assigns) do
    ~H"""
    <line
      data-edge-id={@edge_id}
      data-source={@source_id}
      data-target={@target_id}
      stroke={edge_color(@edge_type)}
      stroke-width={if @live, do: "2", else: "1.5"}
      stroke-dasharray={edge_dash(@edge_type)}
      class={[@live && "ccem-pulse", @class]}
      {@rest}
    />
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp role_color("orchestrator"), do: "oklch(0.68 0.19 280)"
  defp role_color("squadron_lead"), do: "oklch(0.72 0.15 140)"
  defp role_color("swarm_agent"), do: "oklch(0.235 0.017 255)"
  defp role_color("cluster_agent"), do: "oklch(0.205 0.016 255)"
  defp role_color(_individual), do: "oklch(0.175 0.014 255)"

  defp status_color("active"), do: "oklch(0.82 0.18 150)"
  defp status_color("error"), do: "oklch(0.70 0.22 25)"
  defp status_color("complete"), do: "oklch(0.86 0.18 140)"
  defp status_color(_idle), do: "oklch(0.30 0.018 255)"

  defp status_class("active"), do: "ccem-pulse"
  defp status_class(_other), do: nil

  defp edge_color("pubsub"), do: "oklch(0.68 0.19 280)"
  defp edge_color("dependency"), do: "oklch(0.30 0.018 255)"
  defp edge_color("data_flow"), do: "oklch(0.72 0.15 140)"
  defp edge_color(_default), do: "oklch(0.26 0.015 255)"

  defp edge_dash("pubsub"), do: "4 3"
  defp edge_dash("data_flow"), do: "8 4"
  defp edge_dash(_solid), do: nil

  defp truncate_label(label, max_len) when byte_size(label) > max_len do
    String.slice(label, 0, max_len - 1) <> "…"
  end

  defp truncate_label(label, _max_len), do: label
end
