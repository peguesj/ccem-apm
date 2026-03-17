defmodule ApmV5Web.ConversationMonitorLive do
  use ApmV5Web, :live_view

  import ApmV5Web.Components.GettingStartedWizard

  require Logger

  @pubsub_topic "apm:conversations"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic)
      # US-021: EventBus subscription for AG-UI events
      ApmV5.AgUi.EventBus.subscribe("lifecycle:*")
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-100 overflow-hidden">
      <.sidebar_nav current_path="/conversations" />

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
    <.wizard page="agents" dom_id="ccem-wizard-agents-convmon" />
    """
  end

  defp format_dt(nil), do: "?"
  defp format_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%m/%d %H:%M:%S")
  defp format_dt(_), do: "?"
end
