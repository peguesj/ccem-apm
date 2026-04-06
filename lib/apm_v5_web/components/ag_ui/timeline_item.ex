defmodule ApmV5Web.Components.AgUi.TimelineItem do
  @moduledoc "Timeline entry component for activity logs."
  use Phoenix.Component

  attr :timestamp, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :status, :string, default: "idle"
  attr :agent_id, :string, default: nil

  def timeline_item(assigns) do
    assigns = assign(assigns, :time, fmt(assigns.timestamp))
    ~H"""
    <div class="flex gap-3 pb-4">
      <div class={"w-2 h-2 rounded-full mt-2 flex-shrink-0 #{dot(@status)}"} />
      <div class="flex-1 min-w-0">
        <div class="flex justify-between"><span class="text-sm text-white">{@title}</span><span class="text-xs text-gray-500">{@time}</span></div>
        <p class="text-xs text-gray-400 truncate">{@description}</p>
      </div>
    </div>
    """
  end

  defp fmt(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> ts
    end
  end
  defp fmt(_), do: "--:--"

  defp dot("active"), do: "bg-green-400"
  defp dot("error"), do: "bg-red-400"
  defp dot("completed"), do: "bg-blue-400"
  defp dot(_), do: "bg-gray-400"
end
