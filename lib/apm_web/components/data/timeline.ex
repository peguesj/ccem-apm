defmodule ApmWeb.Components.Data.Timeline do
  @moduledoc """
  Tier 3 data-display — Timeline (swim-lane event timeline).

  Sourced from design-intake/v11.0.0/from-designer/apm-shell.jsx
  (used in Live/Timeline and Investigate/Timeline LiveViews per CP-180/CP-182).

  Layout: horizontal swim-lane grid. Each lane corresponds to one item in `lanes`.
  Events are positioned absolutely as fraction of (timestamp - window_start) /
  window_duration along the horizontal axis.

  Lanes data shape: `[%{id: String.t(), label: String.t(), color: String.t()}]`
  Events data shape:
    `[%{id: String.t(), lane_id: String.t(), label: String.t(),
        start_ms: integer(), end_ms: integer() | nil, tone: String.t()}]`

  `window_ms` is the visible time window in milliseconds (e.g. 15 * 60 * 1000).
  `start_ms` is the epoch ms of the left edge.

  Event tone maps to badge tone values for color coding.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-shell.jsx → Timeline LiveView (CP-180)
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :lanes, :list, default: []
  attr :events, :list, default: []
  attr :start_ms, :integer, default: 0
  attr :window_ms, :integer, default: 900_000
  attr :rest, :global

  slot :empty, required: true
  slot :loading, required: true
  slot :error, required: true

  def timeline(assigns) do
    ~H"""
    <div id={@id} class="apm-timeline" {@rest}>
      <%= cond do %>
        <% @lanes == [] && @events == [] -> %>
          {render_slot(@empty)}
        <% true -> %>
          <div class="apm-timeline__lanes">
            <%= for lane <- @lanes do %>
              <div class="apm-timeline__lane" data-lane-id={lane.id}>
                <div class="apm-timeline__lane-label">{lane.label}</div>
                <div
                  class="apm-timeline__lane-track"
                  style={"border-left:2px solid #{lane[:color] || "var(--apm-border-default)"}"}
                >
                  <%= for event <- Enum.filter(@events, &(&1.lane_id == lane.id)) do %>
                    <% left_pct = min(100, max(0, (event.start_ms - @start_ms) / @window_ms * 100))

                    width_pct =
                      if event[:end_ms],
                        do: min(100 - left_pct, (event.end_ms - event.start_ms) / @window_ms * 100),
                        else: 1.0 %>
                    <div
                      class={[
                        "apm-timeline__event",
                        event[:tone] && "apm-timeline__event--#{event.tone}"
                      ]}
                      style={"left:#{left_pct}%;width:max(4px,#{width_pct}%)"}
                      title={event.label}
                      data-event-id={event.id}
                    >
                      <span class="apm-timeline__event-label">{event.label}</span>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
      <% end %>
    </div>
    """
  end
end
