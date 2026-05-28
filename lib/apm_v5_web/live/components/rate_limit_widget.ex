defmodule ApmV5Web.Components.RateLimitWidget do
  @moduledoc """
  LiveComponent widget for the rate-limiting subsystem dashboard.

  Displays:
  - Fuse circuit-breaker states for the three APM-critical fuses
    (`apm_register_fuse`, `apm_heartbeat_fuse`, `apm_notify_fuse`)
  - Adaptive load-factor sparkline (rolling 60-point window, updated via
    PubSub `"apm:rate_limits"` `:adaptive_scaled` events)
  - Top-10 rate-limited agents/sessions placeholder (full query pending
    Hammer enumeration API — see TODO below)
  - Per-formation utilization heat-map placeholder (pending FormationRateLimiter
    query helper — see TODO below)

  ## PubSub subscription

  The parent LiveView (or the page that mounts this component) MUST subscribe
  to `"apm:rate_limits"` and forward relevant `handle_info/2` messages to
  `send_update/2`.  Alternatively, mount this component inside
  `ApmV5Web.RateLimitsLive` which handles the subscription itself.

  ## TODO

  - Top-10 rate-limited agents: requires an ETS enumeration helper in
    `ApmV5.RateLimit` to expose per-key hit counts.  Tracked in rl-s9.
  - Formation utilization heat-map: requires `FormationRateLimiter.utilization/0`
    query helper.  Tracked in rl-s10.
  """

  use ApmV5Web, :live_component

  alias ApmV5.Auth.AdaptiveRateLimiter

  @fuse_names [
    {:apm_register_fuse, "Register"},
    {:apm_heartbeat_fuse, "Heartbeat"},
    {:apm_notify_fuse, "Notify"}
  ]

  @sparkline_capacity 60

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:fuse_states, fetch_fuse_states())
     |> assign(:factor, AdaptiveRateLimiter.adaptive_factor())
     |> assign(:sparkline, [])
     |> assign(:top_limited, [])
     |> assign(:formation_util, [])}
  end

  @impl true
  def update(%{event: {:adaptive_scaled, factor}} = _assigns, socket) do
    sparkline = append_sparkline(socket.assigns.sparkline, factor)

    {:ok,
     socket
     |> assign(:factor, factor)
     |> assign(:sparkline, sparkline)}
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:fuse_states, fetch_fuse_states())}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="rate-limit-widget p-4 bg-base-200 rounded-lg space-y-6">
      <h2 class="text-lg font-semibold">Rate Limiting</h2>

      <!-- Fuse circuit-breaker states -->
      <section>
        <h3 class="text-sm font-medium text-base-content/70 mb-2">Circuit Breakers</h3>
        <div class="grid grid-cols-3 gap-3">
          <%= for {_name, label, state} <- @fuse_states do %>
            <div class={"flex items-center gap-2 px-3 py-2 rounded text-sm font-medium " <> fuse_class(state)}>
              <span class={"w-2 h-2 rounded-full " <> dot_class(state)}></span>
              <%= label %>
              <span class="ml-auto text-xs opacity-75"><%= fuse_label(state) %></span>
            </div>
          <% end %>
        </div>
      </section>

      <!-- Adaptive load factor sparkline -->
      <section>
        <h3 class="text-sm font-medium text-base-content/70 mb-2">
          Adaptive Load Factor
          <span class="ml-2 font-mono text-primary"><%= format_factor(@factor) %></span>
        </h3>
        <div class="h-16 bg-base-300 rounded flex items-end px-1 gap-px overflow-hidden">
          <%= for v <- Enum.take(@sparkline, -60) do %>
            <div
              class="flex-1 min-w-0 bg-primary rounded-sm transition-all duration-300"
              style={"height: #{round(v * 100)}%;"}
            ></div>
          <% end %>
          <%= if @sparkline == [] do %>
            <span class="text-xs text-base-content/40 m-auto">No data yet</span>
          <% end %>
        </div>
      </section>

      <!-- Top rate-limited agents (placeholder) -->
      <section>
        <h3 class="text-sm font-medium text-base-content/70 mb-2">Top Rate-Limited Agents</h3>
        <%= if @top_limited == [] do %>
          <p class="text-xs text-base-content/40 italic">
            TODO (rl-s9): Requires Hammer key-enumeration helper in ApmV5.RateLimit.
          </p>
        <% else %>
          <ul class="space-y-1">
            <%= for {key, hits} <- @top_limited do %>
              <li class="flex justify-between text-sm">
                <span class="font-mono truncate"><%= key %></span>
                <span class="text-error font-semibold"><%= hits %></span>
              </li>
            <% end %>
          </ul>
        <% end %>
      </section>

      <!-- Per-formation utilization heat map (placeholder) -->
      <section>
        <h3 class="text-sm font-medium text-base-content/70 mb-2">Formation Utilization</h3>
        <%= if @formation_util == [] do %>
          <p class="text-xs text-base-content/40 italic">
            TODO (rl-s10): Requires FormationRateLimiter.utilization/0 query helper.
          </p>
        <% else %>
          <div class="grid grid-cols-5 gap-1">
            <%= for {_fid, pct} <- @formation_util do %>
              <div
                class="h-6 rounded text-xs flex items-center justify-center font-mono"
                style={"background: hsl(#{round((1 - pct) * 120)}, 60%, 50%);"}
              >
                <%= round(pct * 100) %>%
              </div>
            <% end %>
          </div>
        <% end %>
      </section>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp fetch_fuse_states do
    Enum.map(@fuse_names, fn {name, label} ->
      state =
        try do
          :fuse.ask(name, :sync)
        rescue
          _ -> :error
        catch
          _, _ -> :error
        end

      {name, label, state}
    end)
  end

  defp append_sparkline(sparkline, factor) do
    (sparkline ++ [factor])
    |> Enum.take(-@sparkline_capacity)
  end

  defp fuse_class(:ok), do: "bg-success/20 text-success"
  defp fuse_class(:blown), do: "bg-error/20 text-error"
  defp fuse_class(_), do: "bg-warning/20 text-warning"

  defp dot_class(:ok), do: "bg-success"
  defp dot_class(:blown), do: "bg-error animate-pulse"
  defp dot_class(_), do: "bg-warning"

  defp fuse_label(:ok), do: "closed"
  defp fuse_label(:blown), do: "blown"
  defp fuse_label(_), do: "unknown"

  defp format_factor(f) when is_float(f), do: :erlang.float_to_binary(f, decimals: 3)
  defp format_factor(_), do: "1.000"
end
