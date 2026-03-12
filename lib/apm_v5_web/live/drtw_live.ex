defmodule ApmV5Web.DrtwLive do
  @moduledoc """
  LiveView for the DRTW (Don't Reinvent The Wheel) discovery framework.
  Surfaces existing solutions and patterns before writing custom code.
  """

  use ApmV5Web, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "DRTW - Don't Reinvent The Wheel")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <.sidebar_nav current_path="/drtw" />
      <div class="flex-1 overflow-y-auto p-6">
        <h1 class="text-2xl font-bold mb-4">Don't Reinvent The Wheel</h1>
        <p class="text-base-content/70">Discovery framework for finding existing solutions before writing custom code.</p>
      </div>
    </div>
    """
  end
end
