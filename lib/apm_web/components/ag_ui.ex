defmodule ApmWeb.Components.AgUi do
  @moduledoc "AG-UI UIKit — reusable LiveView components for CCEM APM dashboard."
  use Phoenix.Component

  alias ApmWeb.Components.AgUi.{StatusBadge, MetricCard, TimelineItem, NodeBadge}

  attr :status, :string, required: true
  attr :size, :atom, default: :md
  attr :label, :string, default: nil
  def status_badge(assigns), do: StatusBadge.status_badge(assigns)

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true
  attr :trend, :atom, default: nil
  attr :color, :string, default: "blue"
  def metric_card(assigns), do: MetricCard.metric_card(assigns)

  attr :timestamp, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :status, :string, default: "idle"
  attr :agent_id, :string, default: nil
  def timeline_item(assigns), do: TimelineItem.timeline_item(assigns)

  attr :level, :string, required: true
  attr :name, :string, required: true
  attr :count, :integer, default: 0
  attr :status, :string, default: "idle"
  def node_badge(assigns), do: NodeBadge.node_badge(assigns)
end
