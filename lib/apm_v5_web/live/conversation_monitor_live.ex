defmodule ApmV5Web.ConversationMonitorLive do
  use ApmV5Web, :live_view
  require Logger

  @pubsub_topic "apm:conversations"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic)
    end
    {:ok, assign_data(socket)}
  end

  @impl true
  def handle_info({:conversations_updated, conversations}, socket) do
    {:noreply, assign(socket, conversations: conversations, active_count: count_active(conversations))}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign_data(socket)}
  end

  defp assign_data(socket) do
    conversations = ApmV5.ConversationWatcher.get_conversations()
    assign(socket,
      conversations: conversations,
      active_count: count_active(conversations),
      page_title: "Conversations"
    )
  end

  defp count_active(conversations), do: Enum.count(conversations, & &1.active)

  attr :active, :string, default: "false"
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, required: true

  defp nav_item(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-colors",
        @active == "true" && "bg-primary text-primary-content font-medium" ||
          "text-base-content/70 hover:bg-base-200 hover:text-base-content"
      ]}
    >
      <.icon name={@icon} class="size-4 flex-shrink-0" />
      <span>{@label}</span>
    </a>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-100 overflow-hidden">
      <aside class="w-52 bg-base-200 border-r border-base-300 flex flex-col flex-shrink-0">
        <div class="p-3 border-b border-base-300">
          <a href="/" class="font-mono font-bold text-sm text-base-content">CCEM APM</a>
          <div class="text-xs text-base-content/40 mt-0.5">v4.0.0</div>
        </div>
        <nav class="flex-1 p-2 space-y-1 overflow-y-auto">
          <.nav_item icon="hero-squares-2x2" label="Dashboard" active="false" href="/" />
          <.nav_item icon="hero-globe-alt" label="All Projects" active="false" href="/apm-all" />
          <.nav_item icon="hero-rectangle-group" label="Formations" active="false" href="/formation" />
          <.nav_item icon="hero-clock" label="Timeline" active="false" href="/timeline" />
          <.nav_item icon="hero-bell" label="Notifications" active="false" href="/notifications" />
          <.nav_item icon="hero-queue-list" label="Background Tasks" active="false" href="/tasks" />
          <.nav_item icon="hero-magnifying-glass" label="Project Scanner" active="false" href="/scanner" />
          <.nav_item icon="hero-bolt" label="Actions" active="false" href="/actions" />
          <.nav_item icon="hero-sparkles" label="Skills" active="false" href="/skills" />
          <.nav_item icon="hero-arrow-path" label="Ralph" active="false" href="/ralph" />
          <.nav_item icon="hero-signal" label="Ports" active="false" href="/ports" />
          <.nav_item icon="hero-chart-bar" label="Analytics" active="false" href="/analytics" />
          <.nav_item icon="hero-heart" label="Health" active="false" href="/health" />
          <.nav_item icon="hero-chat-bubble-left-right" label="Conversations" active="true" href="/conversations" />
          <.nav_item icon="hero-puzzle-piece" label="Plugins" active="false" href="/plugins" />
          <.nav_item icon="hero-book-open" label="Docs" active="false" href="/docs" />
        </nav>
      </aside>

      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="bg-base-200 border-b border-base-300 px-4 py-2 flex items-center gap-3 flex-shrink-0">
          <h1 class="font-semibold text-sm">Conversations</h1>
          <span :if={@active_count > 0} class="badge badge-success badge-sm">
            {@active_count} active
          </span>
          <span :if={@active_count == 0} class="badge badge-ghost badge-sm">idle</span>
          <div class="ml-auto text-xs text-base-content/40">Live via PubSub</div>
        </header>

        <div class="flex-1 overflow-y-auto p-4">
          <div :if={@conversations == []} class="text-center py-8 text-base-content/40 text-sm">
            No sessions found in ~/.claude/projects/
          </div>
          <div class="space-y-2">
            <div
              :for={conv <- @conversations}
              class={[
                "bg-base-200 rounded-lg p-3 border-l-4 transition-all",
                conv.active && "border-success shadow-sm" || "border-base-300 opacity-70"
              ]}
            >
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-2">
                  <span :if={conv.active} class="inline-block size-2 rounded-full bg-success animate-pulse" />
                  <span :if={!conv.active} class="inline-block size-2 rounded-full bg-base-content/20" />
                  <span class="font-medium text-sm">{conv.project}</span>
                </div>
                <span class={["badge badge-xs", conv.active && "badge-success" || "badge-ghost"]}>
                  {if conv.active, do: "active", else: "idle #{conv.idle_minutes}m"}
                </span>
              </div>
              <div class="mt-1 text-xs text-base-content/50 font-mono truncate">
                {conv.session_id}
              </div>
              <div class="mt-1 text-xs text-base-content/40 flex gap-3">
                <span>{conv.size_bytes} bytes</span>
                <span>Modified: {format_dt(conv.last_modified)}</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_dt(nil), do: "?"
  defp format_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%m/%d %H:%M:%S")
  defp format_dt(_), do: "?"
end
