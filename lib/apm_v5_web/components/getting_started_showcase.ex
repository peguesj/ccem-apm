defmodule ApmV5Web.Components.GettingStartedShowcase do
  @moduledoc """
  Getting Started Showcase — two-column modal with Lottie animations
  and dotted slide navigation for CCEM APM feature discovery.

  Slides cover: /upm, /upm sync plan build, /live-integration-testing,
  /double-verify, /pr ship.

  Also provides `lottie_wizard/1` — the dashboard-specific onboarding modal
  that renders at `/` (DashboardLive). Uses the GettingStartedDashboard JS hook
  and storage key `ccem_dashboard_onboarding_v2`.

  Uses lottie-web (loaded from CDN) for animated illustrations.
  WCAG AA compliant with prefers-reduced-motion support.
  Keyboard navigable (Arrow keys, Escape).
  """

  use Phoenix.Component

  @doc """
  Renders the Getting Started Showcase modal overlay.

  The showcase displays on first visit (LocalStorage flag `ccem_showcase_complete`).
  Re-triggerable via Help menu or `?` keyboard shortcut.

  ## Attributes
    * `id` - DOM element ID (default: "getting-started-showcase")
    * `show` - Whether to display the showcase (default: true)
  """
  attr :id, :string, default: "getting-started-showcase"
  attr :show, :boolean, default: true

  @slide_count 5

  def showcase(assigns) do
    assigns = assign(assigns, :slide_count, @slide_count)

    ~H"""
    <div
      id={@id}
      phx-hook="GettingStartedShowcase"
      tabindex="0"
      role="dialog"
      aria-modal="true"
      aria-label="Getting Started with CCEM APM"
      style="display:none;"
      class={[
        "fixed inset-0 z-50 flex items-center justify-center transition-opacity duration-300",
        if(@show, do: "opacity-100", else: "opacity-0 pointer-events-none")
      ]}
    >
      <%!-- Backdrop --%>
      <div
        class="absolute inset-0 bg-black/75 backdrop-blur-sm"
        data-dismiss
        aria-hidden="true"
      >
      </div>

      <%!-- Modal --%>
      <div class="relative w-full max-w-4xl mx-4 bg-base-200 rounded-2xl shadow-2xl border border-base-300 overflow-hidden">
        <%!-- Header --%>
        <div class="flex items-center justify-between px-6 py-3 border-b border-base-300">
          <div class="flex items-center gap-3">
            <div class="w-8 h-8 rounded-lg bg-primary/15 flex items-center justify-center">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="w-4 h-4 text-primary"
                viewBox="0 0 20 20"
                fill="currentColor"
              >
                <path d="M11 3a1 1 0 10-2 0v1a1 1 0 102 0V3zM15.657 5.757a1 1 0 00-1.414-1.414l-.707.707a1 1 0 001.414 1.414l.707-.707zM18 10a1 1 0 01-1 1h-1a1 1 0 110-2h1a1 1 0 011 1zM5.05 6.464A1 1 0 106.464 5.05l-.707-.707a1 1 0 00-1.414 1.414l.707.707zM4 11a1 1 0 100-2H3a1 1 0 000 2h1zM10 17a1 1 0 011-1v-1a1 1 0 10-2 0v1a1 1 0 01-1 1z" />
                <path
                  fill-rule="evenodd"
                  d="M10 18a8 8 0 100-16 8 8 0 000 16zm0-2a6 6 0 100-12 6 6 0 000 12z"
                  clip-rule="evenodd"
                />
              </svg>
            </div>
            <div>
              <h2 class="text-base font-semibold text-base-content">Getting Started</h2>
              <p class="text-[10px] text-base-content/40">CCEM APM Feature Showcase</p>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <span data-counter class="text-xs text-base-content/40 font-mono">1 / 5</span>
            <button
              data-dismiss
              class="btn btn-ghost btn-sm btn-circle"
              aria-label="Close showcase"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-5 w-5"
                viewBox="0 0 20 20"
                fill="currentColor"
              >
                <path
                  fill-rule="evenodd"
                  d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z"
                  clip-rule="evenodd"
                />
              </svg>
            </button>
          </div>
        </div>

        <%!-- Slide content area — managed by JS hook --%>
        <div data-showcase-slides class="px-6 py-6 min-h-[340px]">
          <%!-- Initial loading state; replaced by JS --%>
          <div class="flex items-center justify-center h-[280px]">
            <span class="loading loading-spinner loading-md text-primary"></span>
          </div>
        </div>

        <%!-- Footer with progress dots and nav --%>
        <div class="flex items-center justify-between px-6 py-3 border-t border-base-300">
          <%!-- Progress dots --%>
          <div class="flex items-center gap-1.5" role="tablist" aria-label="Showcase slides">
            <%= for idx <- 0..(@slide_count - 1) do %>
              <button
                data-dot
                class={[
                  "h-2 rounded-full transition-all duration-300 cursor-pointer",
                  if(idx == 0, do: "bg-primary w-6", else: "bg-base-content/20 w-2")
                ]}
                role="tab"
                aria-label={"Slide #{idx + 1}"}
                aria-selected={idx == 0}
              >
              </button>
            <% end %>
          </div>

          <%!-- Navigation --%>
          <div class="flex items-center gap-2">
            <button
              data-skip
              class="btn btn-ghost btn-sm text-base-content/40 text-xs"
            >
              Skip
            </button>
            <button
              data-prev
              class="btn btn-ghost btn-sm invisible"
            >
              Previous
            </button>
            <button
              data-next
              class="btn btn-primary btn-sm"
            >
              Next
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the Dashboard Lottie onboarding wizard.

  Displays on first visit at `/` using LocalStorage key `ccem_dashboard_onboarding_v2`.
  Four slides with detailed APM viewport animations: Dashboard Layout, Agent Fleet,
  Formation Graph, Live Event Stream. Managed entirely by the GettingStartedDashboard
  JS hook — this component is a thin mount point.

  ## Attributes
    * `id` - DOM element ID (default: "getting-started-dashboard")
  """
  attr :id, :string, default: "getting-started-dashboard"

  def lottie_wizard(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="GettingStartedDashboard"
      style="display:none;"
      aria-live="polite"
    >
    </div>
    """
  end
end
