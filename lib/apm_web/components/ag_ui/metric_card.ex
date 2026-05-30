defmodule ApmWeb.Components.AgUi.MetricCard do
  @moduledoc "Stat display card with trend indicator."
  use Phoenix.Component

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true
  attr :trend, :atom, default: nil
  attr :color, :string, default: "blue"

  def metric_card(assigns) do
    ~H"""
    <div class="bg-gray-800 rounded-lg p-4 border border-gray-700">
      <div class="text-2xl font-bold text-white">{@value}</div>
      <div class="text-sm text-gray-400 mt-0.5">{@label}</div>
    </div>
    """
  end
end
