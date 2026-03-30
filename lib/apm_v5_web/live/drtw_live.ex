defmodule ApmV5Web.DrtwLive do
  @moduledoc """
  LiveView for the DRTW (Don't Reinvent The Wheel) discovery framework.
  Surfaces existing solutions and patterns before writing custom code.
  """

  use ApmV5Web, :live_view

  import ApmV5Web.Components.GettingStartedWizard

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "DRTW - Don't Reinvent The Wheel")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <.sidebar_nav current_path="/drtw" />

      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0 relative z-10">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">DRTW</h2>
            <div class="badge badge-sm badge-ghost">Discovery Framework</div>
          </div>
        </header>

        <main class="flex-1 overflow-y-auto p-4 space-y-4">
          <p class="text-base-content/70">Discovery framework for finding existing solutions before writing custom code.</p>
        </main>
      </div>
    </div>
    <.wizard page="welcome" dom_id="ccem-wizard-welcome-drtw" />
    """
  end
end
