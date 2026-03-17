defmodule ApmV5Web.CcemOverviewLive do
  @moduledoc """
  LiveView for the CCEM Management overview hub at `/ccem`.

  Entry point for the CCEM Management section of the dual-section sidebar
  (introduced in v6.0.0). Provides quick-access navigation tiles to all
  CCEM management tools: Showcase, Ports, Actions, and Scanner.

  This page is intentionally stateless — it has no PubSub subscriptions
  and renders from static assigns only. All dynamic content lives in the
  individual management pages it links to.

  ## Navigation Tiles

  - `/showcase` — Project showcase with live agent and UPM data
  - `/ports` — Port registry and conflict detection
  - `/actions` — ActionEngine catalog and run history
  - `/scanner` — Project auto-discovery scanner
  """

  use ApmV5Web, :live_view


  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "CCEM Management")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-100 overflow-hidden">
      <.sidebar_nav current_path="/ccem" />
      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="bg-base-200 border-b border-base-300 px-4 py-2 flex items-center flex-shrink-0">
          <h1 class="font-semibold text-sm">CCEM Management</h1>
        </header>
        <div class="flex-1 overflow-y-auto p-6">
          <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <a href="/showcase" class="bg-base-200 rounded-xl border border-base-300 p-4 hover:border-primary/40 transition-colors flex flex-col items-center gap-2">
              <.icon name="hero-presentation-chart-bar" class="size-8 text-primary" />
              <span class="text-sm font-medium text-base-content">Showcase</span>
            </a>
            <a href="/ports" class="bg-base-200 rounded-xl border border-base-300 p-4 hover:border-primary/40 transition-colors flex flex-col items-center gap-2">
              <.icon name="hero-signal" class="size-8 text-primary" />
              <span class="text-sm font-medium text-base-content">Ports</span>
            </a>
            <a href="/actions" class="bg-base-200 rounded-xl border border-base-300 p-4 hover:border-primary/40 transition-colors flex flex-col items-center gap-2">
              <.icon name="hero-bolt" class="size-8 text-primary" />
              <span class="text-sm font-medium text-base-content">Actions</span>
            </a>
            <a href="/scanner" class="bg-base-200 rounded-xl border border-base-300 p-4 hover:border-primary/40 transition-colors flex flex-col items-center gap-2">
              <.icon name="hero-magnifying-glass" class="size-8 text-primary" />
              <span class="text-sm font-medium text-base-content">Scanner</span>
            </a>
          </div>
        </div>
      </div>
    </div>
    <.wizard page="welcome" dom_id="ccem-wizard-welcome-ccem" />
    """
  end
end
