defmodule ApmWeb.Live.Widgets.MemoryWidgetComponent do
  @moduledoc """
  LiveComponent: Memory Observations widget for the APM dashboard.

  Displays the 5 most recent observations from the ObservationCache ETS layer
  alongside a health indicator reflecting MemoryClientBridge reachability.

  ## Real-time updates

  The parent LiveView (DashboardLive) must subscribe to the `"apm:memory"` PubSub
  topic and call `send_update/2` on receiving `{:observations_updated, _count}`:

      # In DashboardLive.mount/3 (connected branch):
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:memory")

      # In DashboardLive.handle_info/2:
      def handle_info({:observations_updated, _count}, socket) do
        send_update(ApmWeb.Live.Widgets.MemoryWidgetComponent,
          id: "memory-widget",
          config: socket.assigns[:memory_widget_config] || %{}
        )
        {:noreply, socket}
      end

  ## Attrs

  - `id`     - component id (required)
  - `config` - merged widget config map (default: `%{}`)
  """

  use ApmWeb, :live_component

  alias Apm.Plugins.Memory.MemoryClientBridge
  alias Apm.Plugins.Memory.ObservationCache

  @max_observations 5

  @impl true
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def update(assigns, socket) do
    config = assigns[:config] || %{}
    observations = fetch_observations()
    healthy = bridge_healthy?()

    {:ok,
     socket
     |> assign(:config, config)
     |> assign(:observations, observations)
     |> assign(:healthy, healthy)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"memory-widget-#{@id}"} class="h-full flex flex-col bg-base-200">
      <%!-- Header --%>
      <div class="flex items-center justify-between px-3 py-2 border-b border-base-300">
        <div class="flex items-center gap-1.5">
          <svg
            class="w-4 h-4 text-base-content/60 flex-shrink-0"
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
            stroke-width="1.5"
            stroke="currentColor"
            aria-hidden="true"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M12 18v-5.25m0 0a6.01 6.01 0 001.5-.189m-1.5.189a6.01 6.01 0 01-1.5-.189m3.75 7.478a12.06 12.06 0 01-4.5 0m3.75 2.383a14.406 14.406 0 01-3 0M14.25 18v-.192c0-.983.658-1.823 1.508-2.316a7.5 7.5 0 10-7.517 0c.85.493 1.509 1.333 1.509 2.316V18"
            />
          </svg>
          <span class="text-xs font-semibold text-base-content">Memory Observations</span>
        </div>
        <%!-- Health indicator dot --%>
        <div
          class={[
            "w-2.5 h-2.5 rounded-full flex-shrink-0",
            if(@healthy, do: "bg-success", else: "bg-error")
          ]}
          title={if @healthy, do: "claude-mem reachable", else: "claude-mem unreachable"}
          aria-label={if @healthy, do: "Memory service healthy", else: "Memory service unavailable"}
        >
        </div>
      </div>

      <%!-- Observation list --%>
      <div class="flex-1 overflow-y-auto">
        <%= if Enum.empty?(@observations) do %>
          <div class="flex flex-col items-center justify-center h-24 text-base-content/40">
            <svg class="w-5 h-5 mb-1" fill="none" viewBox="0 0 24 24" stroke="currentColor" aria-hidden="true">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"
                d="M9 12h3.75M9 15h3.75M9 18h3.75m3 .75H18a2.25 2.25 0 002.25-2.25V6.108c0-1.135-.845-2.098-1.976-2.192a48.424 48.424 0 00-1.123-.08m-5.801 0c-.065.21-.1.433-.1.664 0 .414.336.75.75.75h4.5a.75.75 0 00.75-.75 2.25 2.25 0 00-.1-.664m-5.8 0A2.251 2.251 0 0113.5 2.25H15c1.012 0 1.867.668 2.15 1.586m-5.8 0c-.376.023-.75.05-1.124.08C9.095 4.01 8.25 4.973 8.25 6.108V8.25m0 0H4.875c-.621 0-1.125.504-1.125 1.125v11.25c0 .621.504 1.125 1.125 1.125h9.75c.621 0 1.125-.504 1.125-1.125V9.375c0-.621-.504-1.125-1.125-1.125H8.25zM6.75 12h.008v.008H6.75V12zm0 3h.008v.008H6.75V15zm0 3h.008v.008H6.75V18z" />
            </svg>
            <p class="text-xs">No observations</p>
          </div>
        <% else %>
          <ul class="divide-y divide-base-300/60">
            <%= for obs <- @observations do %>
              <li class="flex items-start gap-2 px-3 py-2 hover:bg-base-300/30 transition-colors">
                <%!-- Type badge --%>
                <span class={["badge badge-xs flex-shrink-0 mt-0.5", obs_type_badge_class(obs)]}>
                  {obs_type_label(obs)}
                </span>
                <%!-- Truncated content --%>
                <span
                  class="flex-1 text-[11px] text-base-content/80 leading-snug truncate"
                  title={obs_content(obs)}
                >
                  {truncate(obs_content(obs), 50)}
                </span>
                <%!-- Relative time --%>
                <span class="text-[10px] text-base-content/40 flex-shrink-0 whitespace-nowrap">
                  {obs_relative_time(obs)}
                </span>
              </li>
            <% end %>
          </ul>
        <% end %>
      </div>

      <%!-- Footer --%>
      <div class="px-3 py-1.5 border-t border-base-300 flex justify-end">
        <a
          href="/memory"
          class="text-[11px] text-primary hover:underline"
          aria-label="View all memory observations"
        >
          View all
        </a>
      </div>
    </div>
    """
  end

  # ── Private Helpers ────────────────────────────────────────────────────────────

  @spec fetch_observations() :: [map()]
  defp fetch_observations do
    try do
      ObservationCache.list(limit: @max_observations)
      |> Enum.reverse()
    rescue
      _ -> []
    end
  end

  @spec bridge_healthy?() :: boolean()
  defp bridge_healthy? do
    try do
      MemoryClientBridge.health_check() == :ok
    rescue
      _ -> false
    end
  end

  @spec obs_content(map()) :: String.t()
  defp obs_content(%{"narrative" => n}) when is_binary(n), do: n
  defp obs_content(%{narrative: n}) when is_binary(n), do: n
  defp obs_content(%{"content" => c}) when is_binary(c), do: c
  defp obs_content(%{content: c}) when is_binary(c), do: c
  defp obs_content(_), do: "(no content)"

  @spec obs_type_label(map()) :: String.t()
  defp obs_type_label(%{"type" => t}) when is_binary(t), do: t
  defp obs_type_label(%{type: t}) when is_binary(t), do: t
  defp obs_type_label(_), do: "obs"

  @spec obs_type_badge_class(map()) :: String.t()
  defp obs_type_badge_class(obs) do
    case obs_type_label(obs) do
      "error" -> "badge-error"
      "warning" -> "badge-warning"
      "info" -> "badge-info"
      "success" -> "badge-success"
      _ -> "badge-ghost"
    end
  end

  @spec obs_relative_time(map()) :: String.t()
  defp obs_relative_time(obs) do
    raw =
      Map.get(obs, "timestamp") ||
        Map.get(obs, :timestamp) ||
        Map.get(obs, "inserted_at") ||
        Map.get(obs, :inserted_at)

    case parse_timestamp(raw) do
      {:ok, dt} -> format_relative(dt)
      :error -> ""
    end
  end

  @spec parse_timestamp(term()) :: {:ok, DateTime.t()} | :error
  defp parse_timestamp(nil), do: :error

  defp parse_timestamp(%DateTime{} = dt), do: {:ok, dt}

  defp parse_timestamp(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_timestamp(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, dt} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_timestamp(_), do: :error

  @spec format_relative(DateTime.t()) :: String.t()
  defp format_relative(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max) <> "…"
end
