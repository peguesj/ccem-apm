defmodule ApmWeb.Components.AgUi.StatusBadge do
  @moduledoc "Color-coded status badge component."
  use Phoenix.Component

  @colors %{
    "active" => "bg-green-500/20 text-green-400",
    "idle" => "bg-gray-500/20 text-gray-400",
    "error" => "bg-red-500/20 text-red-400",
    "completed" => "bg-blue-500/20 text-blue-400",
    "working" => "bg-amber-500/20 text-amber-400"
  }

  attr :status, :string, required: true
  attr :size, :atom, default: :md
  attr :label, :string, default: nil

  def status_badge(assigns) do
    assigns =
      assign(assigns, :cls, Map.get(@colors, assigns.status, "bg-gray-500/20 text-gray-400"))

    ~H"""
    <span class={"inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium #{@cls}"}>
      <span class={"w-1.5 h-1.5 rounded-full #{dot(@status)}"} />
      {@label || String.capitalize(@status)}
    </span>
    """
  end

  defp dot("active"), do: "bg-green-400"
  defp dot("error"), do: "bg-red-400"
  defp dot("completed"), do: "bg-blue-400"
  defp dot("working"), do: "bg-amber-400"
  defp dot(_), do: "bg-gray-400"
end
