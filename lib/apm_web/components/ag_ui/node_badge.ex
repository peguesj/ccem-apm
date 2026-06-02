defmodule ApmWeb.Components.AgUi.NodeBadge do
  @moduledoc "Architecture hierarchy node badge."
  use Phoenix.Component

  @levels %{
    "fleet" => "bg-purple-500/20 text-purple-300 border-purple-500/40",
    "formation" => "bg-blue-500/20 text-blue-300 border-blue-500/40",
    "squadron" => "bg-cyan-500/20 text-cyan-300 border-cyan-500/40",
    "swarm" => "bg-green-500/20 text-green-300 border-green-500/40",
    "agent" => "bg-gray-500/20 text-gray-300 border-gray-500/40"
  }

  attr :level, :string, required: true
  attr :name, :string, required: true
  attr :count, :integer, default: 0
  attr :status, :string, default: "idle"

  def node_badge(assigns) do
    assigns = assign(assigns, :cls, Map.get(@levels, assigns.level, "bg-gray-500/20 text-gray-300 border-gray-500/40"))
    ~H"""
    <span class={"inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg border text-xs font-medium #{@cls}"}>
      <span class="uppercase tracking-wider opacity-70">{@level}</span>
      <span class="text-white">{@name}</span>
      <span :if={@count > 0} class="opacity-60">{@count}</span>
    </span>
    """
  end
end
