defmodule ApmV5Web.CcemOverviewLive do
  @moduledoc """
  LiveView for the CCEM Management overview hub at `/ccem`.

  Entry point for the CCEM Management section of the dual-section sidebar
  (introduced in v6.0.0). Provides quick-access navigation tiles to all
  CCEM management tools: Showcase, Ports, Actions, and Scanner.

  ## Features

  - Navigation tiles to all CCEM management tools
  - Getting Started wizard (shown on first visit, re-triggerable via header button)
  - AG-UI callout chat — accepts natural language UI commands that update the page
    on the fly via push_event → CcemAssistant JS hook
  - Subscribes to AG-UI PubSub topic for streamed TEXT_MESSAGE responses
  - Emits UPM events to APM for session tracking

  ## AG-UI Chat Commands

  The callout chat supports natural language style commands, e.g.:
  - "make the showcase card blue"
  - "change the size of the title to 2xl"
  - "update ports card border color to orange"

  Style commands are parsed and pushed to the client as `ccem:style_update` events.
  """

  use ApmV5Web, :live_view

  alias ApmV5.ChatStore

  @type_text_message_content AgUi.Core.Events.EventType.text_message_content()

  @pubsub ApmV5.PubSub
  @ag_ui_topic "ag_ui:events"
  @chat_scope "ccem:overview"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, @ag_ui_topic)
    end

    messages = ChatStore.list_messages(@chat_scope, 50)

    socket =
      socket
      |> assign(:page_title, "CCEM Management")
      |> assign(:chat_open, false)
      |> assign(:chat_messages, messages)
      |> assign(:chat_input, "")
      |> assign(:chat_assembling, %{})
      |> assign(:wizard_page, "welcome")
      |> assign(:wizard_visible, false)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-100 overflow-hidden">
      <.sidebar_nav current_path="/ccem" />
      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Header --%>
        <header class="bg-base-200 border-b border-base-300 px-4 py-2 flex items-center gap-3 flex-shrink-0">
          <h1 class="font-semibold text-sm flex-1">CCEM Management</h1>
          <button
            phx-click="toggle_wizard"
            class="btn btn-xs btn-ghost text-base-content/50 gap-1"
            title="Getting Started"
          >
            <.icon name="hero-question-mark-circle" class="size-3.5" />
            <span class="hidden sm:inline">Getting Started</span>
          </button>
        </header>

        <%!-- Nav tiles --%>
        <div class="flex-1 overflow-y-auto p-6">
          <div class="grid grid-cols-2 md:grid-cols-4 gap-4" id="ccem-tiles">
            <a id="ccem-tile-showcase" href="/showcase" class="bg-base-200 rounded-xl border border-base-300 p-4 hover:border-primary/40 transition-colors flex flex-col items-center gap-2 group">
              <.icon name="hero-presentation-chart-bar" class="size-8 text-primary group-hover:scale-110 transition-transform" />
              <span class="text-sm font-medium text-base-content">Showcase</span>
            </a>
            <a id="ccem-tile-ports" href="/ports" class="bg-base-200 rounded-xl border border-base-300 p-4 hover:border-primary/40 transition-colors flex flex-col items-center gap-2 group">
              <.icon name="hero-signal" class="size-8 text-primary group-hover:scale-110 transition-transform" />
              <span class="text-sm font-medium text-base-content">Ports</span>
            </a>
            <a id="ccem-tile-actions" href="/actions" class="bg-base-200 rounded-xl border border-base-300 p-4 hover:border-primary/40 transition-colors flex flex-col items-center gap-2 group">
              <.icon name="hero-bolt" class="size-8 text-primary group-hover:scale-110 transition-transform" />
              <span class="text-sm font-medium text-base-content">Actions</span>
            </a>
            <a id="ccem-tile-scanner" href="/scanner" class="bg-base-200 rounded-xl border border-base-300 p-4 hover:border-primary/40 transition-colors flex flex-col items-center gap-2 group">
              <.icon name="hero-magnifying-glass" class="size-8 text-primary group-hover:scale-110 transition-transform" />
              <span class="text-sm font-medium text-base-content">Scanner</span>
            </a>
          </div>

          <%!-- Status strip --%>
          <div class="mt-6 flex items-center gap-3 text-xs text-base-content/40">
            <span>CCEM v{:apm_v5 |> Application.spec(:vsn) |> to_string()}</span>
            <span>•</span>
            <span>APM :3032</span>
            <span>•</span>
            <a href="/notifications" class="hover:text-primary transition-colors">Notifications</a>
            <span>•</span>
            <a href="/agents" class="hover:text-primary transition-colors">Agents</a>
          </div>
        </div>
      </div>
    </div>

    <%!-- Getting Started wizard --%>
    <.wizard page={@wizard_page} dom_id={"ccem-wizard-overview-#{@wizard_page}"} />

    <%!-- AG-UI Callout Chat --%>
    <div
      id="ccem-assistant"
      phx-hook="CcemAssistant"
      class="fixed bottom-4 right-4 z-[900] flex flex-col items-end gap-2"
    >
      <%!-- Chat panel (shown when open) --%>
      <div
        :if={@chat_open}
        class="w-80 bg-base-200 border border-base-300 rounded-xl shadow-2xl flex flex-col overflow-hidden"
        style="height: 400px;"
      >
        <%!-- Panel header --%>
        <div class="bg-base-300 px-3 py-2 flex items-center gap-2 border-b border-base-300">
          <div class="size-2 rounded-full bg-success animate-pulse"></div>
          <span class="text-xs font-semibold text-base-content flex-1">CCEM Assistant</span>
          <span class="text-[10px] text-base-content/40 font-mono">AG-UI</span>
          <button phx-click="chat:close" class="btn btn-xs btn-ghost btn-circle">
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </div>

        <%!-- Messages --%>
        <div class="flex-1 overflow-y-auto p-2 space-y-2 min-h-0" id="ccem-chat-messages">
          <div :if={@chat_messages == []} id="ccem-chat-empty" class="text-center text-base-content/30 py-8 text-xs">
            Ask me to update this page.<br />
            <span class="text-base-content/20 text-[10px]">"make the showcase card blue"</span>
          </div>
          <div
            :for={msg <- @chat_messages}
            id={"ccem-msg-#{msg["id"]}"}
            class={[
              "rounded-lg p-2 text-xs max-w-[95%]",
              if(msg["role"] == "user", do: "ml-auto bg-primary/20 text-primary-content", else: "bg-base-300")
            ]}
          >
            <div class="flex items-center gap-1 mb-0.5">
              <span class={["badge badge-xs", if(msg["role"] == "user", do: "badge-primary", else: "badge-ghost")]}>
                {msg["role"] || "assistant"}
              </span>
            </div>
            <div class="whitespace-pre-wrap break-words">{msg["content"]}</div>
          </div>
        </div>

        <%!-- Input --%>
        <form phx-submit="chat:send" class="p-2 border-t border-base-300">
          <div class="flex gap-1">
            <input
              type="text"
              name="content"
              value={@chat_input}
              placeholder="Update this page..."
              class="input input-xs input-bordered flex-1 bg-base-100"
              autocomplete="off"
              phx-change="chat:input"
              id="ccem-chat-input"
            />
            <button type="submit" class="btn btn-xs btn-primary">
              <.icon name="hero-paper-airplane" class="size-3" />
            </button>
          </div>
        </form>
      </div>

      <%!-- FAB toggle button --%>
      <button
        phx-click="chat:toggle"
        class={[
          "size-12 rounded-full shadow-lg flex items-center justify-center transition-all",
          "hover:scale-110 active:scale-95",
          if(@chat_open,
            do: "bg-base-300 text-base-content border border-base-300",
            else: "bg-gradient-to-br from-purple-500 to-indigo-600 text-white"
          )
        ]}
        title="CCEM Assistant"
      >
        <.icon name={if @chat_open, do: "hero-x-mark", else: "hero-chat-bubble-left-ellipsis"} class="size-5" />
      </button>
    </div>
    """
  end

  # --- Events ---

  @impl true
  def handle_event("toggle_wizard", _params, socket) do
    {:noreply, push_event(socket, "ccem:wizard_trigger", %{page: socket.assigns.wizard_page})}
  end

  def handle_event("chat:toggle", _params, socket) do
    {:noreply, assign(socket, :chat_open, !socket.assigns.chat_open)}
  end

  def handle_event("chat:close", _params, socket) do
    {:noreply, assign(socket, :chat_open, false)}
  end

  def handle_event("chat:input", %{"content" => val}, socket) do
    {:noreply, assign(socket, :chat_input, val)}
  end

  def handle_event("chat:send", %{"content" => content}, socket) when content != "" do
    {:ok, _user_msg} = ChatStore.send_message(@chat_scope, content, %{"role" => "user"})

    # Emit USER_MESSAGE AG-UI event
    Task.start(fn ->
      ApmV5.EventStream.emit(AgUi.Core.Events.EventType.messages_snapshot(), %{
        agent_id: "ccem-assistant",
        messages: [%{role: "user", content: content}]
      })
    end)

    # Process command and build reply
    {reply, style_events} = process_ccem_command(content)

    {:ok, _reply_msg} = ChatStore.send_message(@chat_scope, reply, %{"role" => "assistant", "source" => "ccem_assistant"})

    messages = ChatStore.list_messages(@chat_scope, 50)

    socket =
      socket
      |> assign(:chat_messages, messages)
      |> assign(:chat_input, "")

    # Push style updates to client
    socket =
      Enum.reduce(style_events, socket, fn evt, acc ->
        push_event(acc, "ccem:style_update", evt)
      end)

    {:noreply, socket}
  end

  def handle_event("chat:send", _params, socket), do: {:noreply, socket}

  # --- AG-UI PubSub ---

  @impl true
  def handle_info({:ag_ui_event, event}, socket) do
    case event.type do
      @type_text_message_content ->
        if get_in(event.data, [:agent_id]) == "ccem-assistant" do
          {:noreply, push_event(socket, "ccem:stream_token", %{content: event.data[:content]})}
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Command Processing ---

  # Parses natural language UI commands and returns {reply_text, [style_events]}
  # Style events: %{selector: css_selector, property: css_property, value: css_value}
  @spec process_ccem_command(String.t()) :: {String.t(), [map()]}
  defp process_ccem_command(content) do
    lower = String.downcase(content)

    cond do
      # Color updates: "make/change/set X [color/bg/border] [to/=] Y"
      color_match = Regex.run(~r/(?:make|change|set|update)\s+(?:the\s+)?(\w+)\s+(?:card\s+)?(?:color|background|bg|border)\s+(?:to\s+)?(\S+)/i, lower) ->
        [_, target, color] = color_match
        {selector, property} = resolve_color_target(target, lower)
        css_val = normalize_color(color)
        events = [%{selector: selector, property: property, value: css_val, label: "#{target} #{property}"}]
        {"Updated #{target} #{property} to #{css_val}.", events}

      # Text size: "make/change X [text/font] [size/larger/smaller] [to/=] Y"
      size_match = Regex.run(~r/(?:make|change|set|update)\s+(?:the\s+)?(\w+)\s+(?:card\s+)?(?:text|font)?\s*(?:size|larger|smaller)\s*(?:to\s+)?(\S+)?/i, lower) ->
        [_, target | rest] = size_match
        size = case rest do
          [s] when s != "" -> s
          _ -> if String.contains?(lower, "larger"), do: "larger", else: "smaller"
        end
        selector = resolve_tile_selector(target)
        css_val = normalize_size(size)
        events = [%{selector: "#{selector} span", property: "font-size", value: css_val, label: "#{target} text size"}]
        {"Updated #{target} text size to #{css_val}.", events}

      # Reset: "reset [all]"
      String.contains?(lower, "reset") ->
        events = [%{selector: "#ccem-tiles a", property: "reset", value: "all", label: "all tiles"}]
        {"Reset all tile styles.", events}

      # Help
      String.contains?(lower, "help") || String.contains?(lower, "what can") ->
        help = """
        I can update CCEM Management page elements on the fly.

        Try:
        • "make the showcase card blue"
        • "change the ports card background to dark"
        • "set the actions card border color to orange"
        • "make the scanner text size larger"
        • "reset all"

        Targets: showcase, ports, actions, scanner, all
        """
        {String.trim(help), []}

      # Unknown
      true ->
        {"I can help you update elements on this page. Try: \"make the showcase card blue\" or type \"help\" for examples.", []}
    end
  end

  defp resolve_color_target(target, content) do
    selector = resolve_tile_selector(target)
    cond do
      String.contains?(content, "background") || String.contains?(content, "bg") ->
        {selector, "background-color"}
      String.contains?(content, "border") ->
        {selector, "border-color"}
      true ->
        {selector, "color"}
    end
  end

  defp resolve_tile_selector("showcase"), do: "#ccem-tile-showcase"
  defp resolve_tile_selector("ports"), do: "#ccem-tile-ports"
  defp resolve_tile_selector("actions"), do: "#ccem-tile-actions"
  defp resolve_tile_selector("scanner"), do: "#ccem-tile-scanner"
  defp resolve_tile_selector("all"), do: "#ccem-tiles a"
  defp resolve_tile_selector(_), do: "#ccem-tiles a"

  defp normalize_color("blue"), do: "#3b82f6"
  defp normalize_color("red"), do: "#ef4444"
  defp normalize_color("green"), do: "#22c55e"
  defp normalize_color("orange"), do: "#f97316"
  defp normalize_color("purple"), do: "#a855f7"
  defp normalize_color("pink"), do: "#ec4899"
  defp normalize_color("yellow"), do: "#eab308"
  defp normalize_color("dark"), do: "#1e293b"
  defp normalize_color("gray"), do: "#6b7280"
  defp normalize_color("white"), do: "#ffffff"
  defp normalize_color(other), do: other

  defp normalize_size("larger"), do: "1rem"
  defp normalize_size("smaller"), do: "0.625rem"
  defp normalize_size("xl"), do: "1.25rem"
  defp normalize_size("2xl"), do: "1.5rem"
  defp normalize_size("lg"), do: "1.125rem"
  defp normalize_size("sm"), do: "0.875rem"
  defp normalize_size("xs"), do: "0.75rem"
  defp normalize_size(other), do: other
end
