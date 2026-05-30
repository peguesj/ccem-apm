defmodule ApmV5Web.Components.Data.Sparkline do
  @moduledoc """
  Tier 3 data-display — Sparkline (mini SVG chart with optional live trailing dot).

  Sourced from design-intake/v11.0.0/from-designer/apm-data.jsx (Sparkline).

  SVG viewBox 0 0 100 {height}, width 100%, preserveAspectRatio none.
  Line: polyline, stroke {color}, strokeWidth 1.2, strokeLinejoin round,
    vectorEffect non-scaling-stroke.
  Fill: polygon from 0,height through points to w,height, fill {color} opacity 0.1.
  Trailing dot (live=true): circle at last data point, r 1.8, fill {color},
    animation `apm-spark-dot 1.5s var(--apm-ease-out) infinite` (radius pulse + position ease).
    Reduce-motion: position snap, no pulse.

  `data` is a list of numbers. Minimum 2 points required for a valid polyline.
  Caller passes the SparklineDot hook registration via `live` attr.

  ## JS hook
  # TODO: colocate data/sparkline.hook.js — SparklineDot trailing dot animation
  # phx-hook="SparklineDot" applied to the SVG element when live is true.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-data.jsx → Sparkline
  - Motion spec: motion.md §Loading patterns → Sparkline trailing dot
  """
  use Phoenix.Component

  attr :data, :list, required: true
  attr :height, :integer, default: 28
  attr :color, :string, default: "var(--apm-accent)"
  attr :fill, :boolean, default: true
  attr :live, :boolean, default: false
  attr :id, :string, default: nil
  attr :rest, :global

  def sparkline(assigns) do
    assigns =
      assign(assigns, :points, compute_sparkline_points(assigns.data, 100, assigns.height))

    ~H"""
    <svg
      id={@id}
      viewBox={"0 0 100 #{@height}"}
      width="100%"
      height={@height}
      preserveAspectRatio="none"
      class={["apm-sparkline", @live && "apm-sparkline--live"]}
      phx-hook={if @live, do: "SparklineDot", else: nil}
      data-color={@live && @color}
      style="display:block;overflow:visible"
      {@rest}
    >
      <%= if @fill && @points.pts != "" do %>
        <polygon
          points={"0,#{@height} #{@points.pts} 100,#{@height}"}
          fill={@color}
          fill-opacity="0.1"
        />
      <% end %>
      <%= if @points.pts != "" do %>
        <polyline
          points={@points.pts}
          fill="none"
          stroke={@color}
          stroke-width="1.2"
          vector-effect="non-scaling-stroke"
          stroke-linejoin="round"
        />
      <% end %>
      <%= if @live && @points.last_x && @points.last_y do %>
        <circle
          cx={@points.last_x}
          cy={@points.last_y}
          r="1.8"
          fill={@color}
          class="apm-spark-dot"
        />
      <% end %>
    </svg>
    """
  end

  defp compute_sparkline_points([], _w, _h), do: %{pts: "", last_x: nil, last_y: nil}

  defp compute_sparkline_points([_], _w, h),
    do: %{pts: "0,#{h / 2}", last_x: "0", last_y: "#{h / 2}"}

  defp compute_sparkline_points(data, w, h) do
    max_v = Enum.max(data)
    min_v = Enum.min(data)
    range = max(max_v - min_v, 1)
    n = length(data)
    step = w / (n - 1)

    pts =
      data
      |> Enum.with_index()
      |> Enum.map(fn {v, i} ->
        x = Float.round(i * step, 1)
        y = Float.round((1 - (v - min_v) / range) * h, 1)
        "#{x},#{y}"
      end)
      |> Enum.join(" ")

    last_v = List.last(data)
    last_x = Float.round((n - 1) * step, 1)
    last_y = Float.round((1 - (last_v - min_v) / range) * h, 1)

    %{pts: pts, last_x: "#{last_x}", last_y: "#{last_y}"}
  end
end
