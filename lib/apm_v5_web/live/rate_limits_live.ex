defmodule ApmV5Web.RateLimitsLive do
  @moduledoc """
  Standalone LiveView page at `/rate-limits`.

  Hosts `ApmV5Web.Components.RateLimitWidget` and subscribes to the
  `"apm:rate_limits"` PubSub topic so the widget receives live adaptive-factor
  updates.
  """

  use ApmV5Web, :live_view

  alias ApmV5.Auth.AdaptiveRateLimiter

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:rate_limits")
      :timer.send_interval(10_000, self(), :refresh_fuses)
    end

    {:ok,
     socket
     |> assign(:page_title, "Rate Limits")
     |> assign(:active_nav, :rate_limits)
     |> assign(:factor, AdaptiveRateLimiter.adaptive_factor())
     |> assign(:sidebar_collapsed, false)
     |> assign(:inspector_open, false)
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  @impl true
  def handle_info({:adaptive_scaled, factor}, socket) do
    send_update(ApmV5Web.Components.RateLimitWidget,
      id: "rate-limit-widget",
      event: {:adaptive_scaled, factor}
    )

    {:noreply, assign(socket, :factor, factor)}
  end

  def handle_info(:refresh_fuses, socket) do
    # Trigger a no-event update so the widget re-fetches fuse states
    send_update(ApmV5Web.Components.RateLimitWidget,
      id: "rate-limit-widget"
    )

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto p-6">
      <div class="max-w-3xl mx-auto">
        <div class="mb-6">
          <h1 class="text-2xl font-bold">Rate Limits</h1>
          <p class="text-base-content/60 text-sm mt-1">
            Circuit breakers, adaptive load factor, and formation budgets.
          </p>
        </div>

        <.live_component
          module={ApmV5Web.Components.RateLimitWidget}
          id="rate-limit-widget"
        />
      </div>
    </div>
    """
  end
end
