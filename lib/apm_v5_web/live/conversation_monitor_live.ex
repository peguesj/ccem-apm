defmodule ApmV5Web.ConversationMonitorLive do
  @moduledoc """
  LiveView for monitoring active Claude Code conversation sessions at /conversations.

  Displays session-level context, token counts, and tool call history
  sourced from ConversationWatcher. Includes a full-width bottom tray with
  conversation inspector: live message streaming, log, actions, execution,
  and UPM/Formation tabs.
  """

  use ApmV5Web, :live_view

  import ApmV5Web.Components.GettingStartedWizard
  import ApmV5Web.Components.ConversationDrawer

  require Logger

  alias ApmV5.Plugins.Memory.ConversationMemoryCorrelator

  @pubsub_topic "apm:conversations"
  @live_poll_ms 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic)
      ApmV5.AgUi.EventBus.subscribe("lifecycle:*")
    end

    socket =
      socket
      |> assign_data()
      |> assign(
        tray_open: false,
        tray_tab: "live",
        drawer_height: :collapsed,
        selected_conversations: MapSet.new(),
        conversation_messages: [],
        live_offsets: %{},
        live_messages: [],
        related_sessions: [],
        show_related: false,
        memory_observations: []
      )
      |> assign_tray_context()

    {:ok, socket |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  # ── Events ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("toggle_tray", _params, socket) do
    new_height =
      case socket.assigns.drawer_height do
        :collapsed -> :expanded
        _ -> :collapsed
      end

    {:noreply, assign(socket, drawer_height: new_height, tray_open: new_height != :collapsed)}
  end

  @impl true
  def handle_event("drawer_resized", %{"height" => raw_height}, socket) do
    px = raw_height |> to_string() |> Integer.parse() |> elem(0)
    clamped = ApmV5Web.Components.ConversationDrawer.clamp_height(px)

    new_height = if clamped <= 60, do: :collapsed, else: clamped

    {:noreply,
     assign(socket, drawer_height: new_height, tray_open: new_height != :collapsed)}
  end

  @impl true
  def handle_event("drawer_collapse", _params, socket) do
    {:noreply, assign(socket, drawer_height: :collapsed, tray_open: false)}
  end

  @impl true
  def handle_event("drawer_toggle", _params, socket) do
    handle_event("toggle_tray", %{}, socket)
  end

  @impl true
  def handle_event("drawer_fullscreen", _params, socket) do
    {:noreply, assign(socket, drawer_height: :fullscreen, tray_open: true)}
  end

  @impl true
  def handle_event("select_tray_tab", %{"tab" => tab}, socket) do
    socket =
      socket
      |> assign(tray_tab: tab, tray_open: true, drawer_height: expand_if_collapsed(socket.assigns.drawer_height))
      |> maybe_start_live_poll(tab)

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_conversation", %{"path" => path}, socket) do
    selected = socket.assigns.selected_conversations

    selected =
      if MapSet.member?(selected, path) do
        MapSet.delete(selected, path)
      else
        MapSet.put(selected, path)
      end

    socket =
      socket
      |> assign(selected_conversations: selected)
      |> load_selected_messages()
      |> find_related_sessions()
      |> load_memory_observations()
      |> maybe_start_live_poll(socket.assigns.tray_tab)

    {:noreply, socket}
  end

  @impl true
  def handle_event("include_related", _params, socket) do
    related_paths =
      socket.assigns.related_sessions
      |> Enum.map(& &1.path)

    selected =
      Enum.reduce(related_paths, socket.assigns.selected_conversations, fn p, acc ->
        MapSet.put(acc, p)
      end)

    socket =
      socket
      |> assign(selected_conversations: selected)
      |> load_selected_messages()
      |> maybe_start_live_poll(socket.assigns.tray_tab)

    {:noreply, socket}
  end

  # ── Info handlers ───────────────────────────────────────────────────

  @impl true
  def handle_info({:conversations_updated, conversations}, socket) do
    socket =
      socket
      |> assign(conversations: conversations, active_count: count_active(conversations))
      |> assign_tray_context()

    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, socket |> assign_data() |> assign_tray_context()}
  end

  @impl true
  def handle_info(:poll_live, socket) do
    if socket.assigns.tray_tab == "live" and socket.assigns.tray_open do
      socket = poll_live_messages(socket)
      Process.send_after(self(), :poll_live, @live_poll_ms)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # ── Private: data loading ───────────────────────────────────────────

  defp assign_data(socket) do
    conversations = ApmV5.ConversationWatcher.get_conversations()

    assign(socket,
      conversations: conversations,
      active_count: count_active(conversations),
      page_title: "Conversations"
    )
  end

  defp count_active(conversations), do: Enum.count(conversations, & &1.active)

  defp assign_tray_context(socket) do
    agents = ApmV5.AgentRegistry.list_agents()

    formation_agents =
      Enum.filter(agents, fn a -> Map.get(a, :formation_id) not in [nil, ""] end)

    upm_agents =
      Enum.filter(agents, fn a -> Map.get(a, :formation_role) not in [nil, ""] end)

    tool_call_entries =
      socket.assigns.conversations
      |> Enum.filter(& &1.active)

    assign(socket,
      tray_agents: agents,
      tray_formation_agents: formation_agents,
      tray_upm_agents: upm_agents,
      tray_tool_entries: tool_call_entries,
      has_formation: formation_agents != [],
      has_upm: upm_agents != []
    )
  end

  defp load_selected_messages(socket) do
    selected = socket.assigns.selected_conversations

    if MapSet.size(selected) == 0 do
      assign(socket, conversation_messages: [])
    else
      messages =
        selected
        |> MapSet.to_list()
        |> Enum.flat_map(fn path ->
          case ApmV5.ConversationReader.read_recent(path, 50) do
            {:ok, msgs} -> Enum.map(msgs, &Map.put(&1, :source_path, path))
            _ -> []
          end
        end)
        |> Enum.reject(fn m -> is_nil(m.timestamp) end)
        |> Enum.sort_by(& &1.timestamp)

      assign(socket, conversation_messages: messages)
    end
  end

  defp find_related_sessions(socket) do
    selected = socket.assigns.selected_conversations

    if MapSet.size(selected) == 0 do
      assign(socket, related_sessions: [], show_related: false)
    else
      related =
        selected
        |> MapSet.to_list()
        |> Enum.flat_map(fn path ->
          case ApmV5.ConversationReader.find_related(path) do
            {:ok, rels} -> rels
            _ -> []
          end
        end)
        |> Enum.reject(fn r -> MapSet.member?(selected, r.path) end)
        |> Enum.uniq_by(& &1.path)

      assign(socket, related_sessions: related, show_related: related != [])
    end
  end

  defp maybe_start_live_poll(socket, "live") do
    if MapSet.size(socket.assigns.selected_conversations) > 0 do
      # Initialize offsets for selected files
      offsets =
        socket.assigns.selected_conversations
        |> MapSet.to_list()
        |> Enum.reduce(socket.assigns.live_offsets, fn path, acc ->
          if Map.has_key?(acc, path) do
            acc
          else
            case ApmV5.ConversationReader.file_size(path) do
              {:ok, size} -> Map.put(acc, path, size)
              _ -> Map.put(acc, path, 0)
            end
          end
        end)

      Process.send_after(self(), :poll_live, @live_poll_ms)
      assign(socket, live_offsets: offsets, live_messages: [])
    else
      socket
    end
  end

  defp maybe_start_live_poll(socket, _tab), do: socket

  defp load_memory_observations(socket) do
    selected = socket.assigns.selected_conversations

    if MapSet.size(selected) == 0 do
      assign(socket, :memory_observations, [])
    else
      observations =
        selected
        |> MapSet.to_list()
        |> Enum.flat_map(fn path ->
          session_id = extract_session_id_from_path(path)

          case session_id && ConversationMemoryCorrelator.correlate_session(session_id) do
            {:ok, obs} -> obs
            _ -> []
          end
        end)
        |> Enum.uniq_by(fn o -> o["id"] || o[:id] end)
        |> Enum.sort_by(fn o -> o["timestamp"] || o[:timestamp] || "" end)

      assign(socket, :memory_observations, observations)
    end
  end

  defp extract_session_id_from_path(path) when is_binary(path) do
    path |> Path.basename() |> Path.rootname()
  end

  defp extract_session_id_from_path(_), do: nil

  defp poll_live_messages(socket) do
    selected = socket.assigns.selected_conversations

    if MapSet.size(selected) == 0 do
      socket
    else
      {new_offsets, new_msgs} =
        selected
        |> MapSet.to_list()
        |> Enum.reduce({socket.assigns.live_offsets, []}, fn path, {offsets, msgs} ->
          offset = Map.get(offsets, path, 0)

          case ApmV5.ConversationReader.read_from_offset(path, offset) do
            {:ok, new_messages, new_offset} ->
              tagged = Enum.map(new_messages, &Map.put(&1, :source_path, path))
              {Map.put(offsets, path, new_offset), msgs ++ tagged}

            _ ->
              {offsets, msgs}
          end
        end)

      existing = socket.assigns.live_messages
      # Keep last 200 live messages
      combined = (existing ++ new_msgs) |> Enum.take(-200)

      assign(socket, live_offsets: new_offsets, live_messages: combined)
    end
  end

  # ── Helpers for conversation file path ──────────────────────────────

  defp conversation_file_path(conv) do
    projects_dir = Path.expand("~/.claude/projects")
    # Reconstruct the path from the conversation data
    # ConversationWatcher stores project (derived from dir) and file (basename)
    # We need to find the actual directory
    find_jsonl_path(projects_dir, conv.file)
  end

  defp find_jsonl_path(projects_dir, filename) do
    case File.ls(projects_dir) do
      {:ok, dirs} ->
        Enum.find_value(dirs, fn dir ->
          full = Path.join([projects_dir, dir, filename])
          if File.exists?(full), do: full
        end)

      _ ->
        nil
    end
  end

  # ── Render ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <.sidebar_nav current_path="/conversations" />

      <div class="flex-1 flex flex-col overflow-hidden relative">
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0 relative z-10">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Conversations</h2>
            <span :if={@active_count > 0} class="badge badge-success badge-sm">
              {@active_count} active
            </span>
            <span :if={@active_count == 0} class="badge badge-ghost badge-sm">idle</span>
          </div>
          <div class="flex items-center gap-2">
            <span :if={MapSet.size(@selected_conversations) > 0} class="text-xs text-primary">
              {MapSet.size(@selected_conversations)} selected
            </span>
            <span class="text-xs text-base-content/40">Live via PubSub</span>
          </div>
        </header>

        <div class={[
          "flex-1 overflow-y-auto p-4 transition-all duration-300",
          @tray_open && "pb-[42vh]" || "pb-16"
        ]}
        >
          <div :if={@conversations == []} class="text-center py-8 text-base-content/40 text-sm">
            No sessions found in ~/.claude/projects/
          </div>
          <div class="space-y-2">
            <div
              :for={conv <- @conversations}
              phx-click="toggle_conversation"
              phx-value-path={conversation_file_path(conv)}
              class={[
                "bg-base-200 rounded-lg p-3 border-l-4 transition-all cursor-pointer hover:bg-base-100",
                conv.active && "border-success shadow-sm" || "border-base-300 opacity-70",
                conversation_file_path(conv) && MapSet.member?(@selected_conversations, conversation_file_path(conv)) && "ring-2 ring-primary/50 bg-base-100"
              ]}
            >
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-2">
                  <input
                    type="checkbox"
                    class="checkbox checkbox-xs checkbox-primary"
                    checked={conversation_file_path(conv) && MapSet.member?(@selected_conversations, conversation_file_path(conv))}
                    phx-click="toggle_conversation"
                    phx-value-path={conversation_file_path(conv)}
                  />
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

        <%!-- Conversation Inspector drawer --%>
        <.conversation_drawer
          drawer_height={@drawer_height}
          tray_tab={@tray_tab}
          tray_tabs={tray_tabs(assigns)}
          show_related={@show_related}
          related_sessions={@related_sessions}
        >
          {render_tray_tab(assigns)}
        </.conversation_drawer>
      </div>
    </div>
    <.wizard page="agents" dom_id="ccem-wizard-agents-convmon" />
    """
  end

  defp tray_tabs(assigns) do
    live_count = length(assigns.live_messages)
    log_count = length(assigns.conversation_messages)
    actions_count = assigns.conversation_messages |> extract_tool_entries() |> length()
    memory_count = length(assigns.memory_observations)

    base = [
      %{id: "live", label: "Live", count: live_count},
      %{id: "log", label: "Log", count: log_count},
      %{id: "actions", label: "Actions", count: actions_count},
      %{id: "execution", label: "Execution", count: 0},
      %{id: "memory", label: "Memory", count: memory_count}
    ]

    upm = if assigns.has_upm, do: [%{id: "upm", label: "UPM", count: length(assigns.tray_upm_agents)}], else: []
    formation = if assigns.has_formation, do: [%{id: "formation", label: "Formation", count: length(assigns.tray_formation_agents)}], else: []

    base ++ upm ++ formation
  end

  defp expand_if_collapsed(:collapsed), do: :expanded
  defp expand_if_collapsed(height), do: height

  # ── Live tab ────────────────────────────────────────────────────────

  defp render_tray_tab(%{tray_tab: "live"} = assigns) do
    ~H"""
    <div class="space-y-1" id="live-messages" phx-hook="ScrollBottom">
      <div :if={MapSet.size(@selected_conversations) == 0} class="text-xs text-base-content/40 py-4 text-center">
        Select a conversation above to see live messages
      </div>
      <div :if={@live_messages == [] and MapSet.size(@selected_conversations) > 0} class="text-xs text-base-content/40 py-4 text-center">
        Watching for new messages... (polling every 3s)
      </div>
      <div
        :for={msg <- @live_messages}
        class={[
          "text-xs font-mono rounded px-2 py-1 animate-fade-in",
          msg.type == "user" && "bg-primary/10 border-l-2 border-primary",
          msg.type == "assistant" && "bg-base-300/50 border-l-2 border-success",
          msg.type == "system" && "bg-warning/10 border-l-2 border-warning"
        ]}
      >
        <div class="flex items-center gap-2 mb-0.5">
          <span class={[
            "badge badge-xs",
            msg.type == "user" && "badge-primary",
            msg.type == "assistant" && "badge-success",
            msg.type == "system" && "badge-warning"
          ]}>{msg.type}</span>
          <span class="text-base-content/30">{format_ts(msg.timestamp)}</span>
          <span :if={length(msg.tool_calls) > 0} class="text-info/60">
            {length(msg.tool_calls)} tool call(s)
          </span>
        </div>
        <div :if={msg.content} class="text-base-content/70 truncate max-w-full">
          {truncate(msg.content, 200)}
        </div>
        <div :for={tc <- msg.tool_calls} class="text-info/70 ml-4">
          -> {tc.name}
        </div>
      </div>
    </div>
    """
  end

  # ── Log tab ─────────────────────────────────────────────────────────

  defp render_tray_tab(%{tray_tab: "log"} = assigns) do
    ~H"""
    <div class="space-y-1">
      <div :if={MapSet.size(@selected_conversations) == 0} class="text-xs text-base-content/40 py-4 text-center">
        Select a conversation to view message log
      </div>
      <div :if={@conversation_messages == [] and MapSet.size(@selected_conversations) > 0} class="text-xs text-base-content/40 py-4 text-center">
        No messages found in selected conversation(s)
      </div>
      <div
        :for={msg <- @conversation_messages}
        title={format_ts(msg.timestamp)}
        class={[
          "flex items-center gap-2 text-xs font-mono rounded px-2 py-0.5 cursor-default",
          "hover:bg-base-300/80 transition-colors",
          msg.type == "user" && "bg-primary/10",
          msg.type == "assistant" && "bg-base-300/50",
          msg.type == "system" && "bg-warning/10"
        ]}
      >
        <span class={[
          "badge badge-xs shrink-0",
          msg.type == "user" && "badge-primary",
          msg.type == "assistant" && "badge-success",
          msg.type == "system" && "badge-warning"
        ]}>{msg.type}</span>
        <span class="text-base-content/30 shrink-0 w-14">{relative_ts(msg.timestamp)}</span>
        <span class="text-base-content/70 flex-1 truncate">
          {truncate(msg.content || "(no text content)", 200)}
        </span>
      </div>
    </div>
    """
  end

  # ── Actions tab ─────────────────────────────────────────────────────

  defp render_tray_tab(%{tray_tab: "actions"} = assigns) do
    ~H"""
    <div class="space-y-1">
      <div :if={MapSet.size(@selected_conversations) == 0} class="text-xs text-base-content/40 py-4 text-center">
        Select a conversation to view tool actions
      </div>
      <%= if MapSet.size(@selected_conversations) > 0 do %>
        <% tool_entries = extract_tool_entries(@conversation_messages) %>
        <div :if={tool_entries == []} class="text-xs text-base-content/40 py-4 text-center">
          No tool calls found in selected conversation(s)
        </div>
        <div
          :for={entry <- tool_entries}
          class="flex items-center gap-2 text-xs font-mono bg-base-300/50 rounded px-2 py-1"
        >
          <span class={[
            "badge badge-xs",
            entry.type == "tool_use" && "badge-info",
            entry.type == "tool_result" && (if entry.is_error, do: "badge-error", else: "badge-success")
          ]}>
            {if entry.type == "tool_use", do: "call", else: if(entry.is_error, do: "err", else: "ok")}
          </span>
          <span class="text-info/80 w-24 truncate">{entry.name || "-"}</span>
          <span class="text-base-content/30 w-16">{format_ts(entry.timestamp)}</span>
          <span class="text-base-content/50 flex-1 truncate">{entry.preview}</span>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Execution tab ───────────────────────────────────────────────────

  defp render_tray_tab(%{tray_tab: "execution"} = assigns) do
    ~H"""
    <div class="space-y-1">
      <div :if={MapSet.size(@selected_conversations) == 0} class="text-xs text-base-content/40 py-4 text-center">
        Select a conversation to view execution timeline
      </div>
      <%= if MapSet.size(@selected_conversations) > 0 do %>
        <% turns = build_execution_timeline(@conversation_messages) %>
        <div :if={turns == []} class="text-xs text-base-content/40 py-4 text-center">
          No execution data in selected conversation(s)
        </div>
        <div
          :for={{turn, idx} <- Enum.with_index(turns, 1)}
          class="flex items-center gap-2 text-xs font-mono bg-base-300/50 rounded px-2 py-1"
        >
          <span class="badge badge-xs badge-outline badge-primary w-6 text-center">{idx}</span>
          <span class={[
            "badge badge-xs",
            turn.type == "user" && "badge-primary",
            turn.type == "assistant" && "badge-success",
            turn.type == "system" && "badge-warning"
          ]}>{turn.type}</span>
          <span class="text-base-content/30 w-16">{format_ts(turn.timestamp)}</span>
          <span :if={turn.usage} class="text-info/60 w-20 text-right">
            {turn.usage.input_tokens + turn.usage.output_tokens} tok
          </span>
          <span :if={!turn.usage} class="text-base-content/20 w-20 text-right">-</span>
          <span class="text-base-content/50 w-10 text-right">
            {length(turn.tool_calls)} tc
          </span>
          <span class="text-base-content/60 flex-1 truncate">
            {truncate(turn.content || "", 120)}
          </span>
        </div>
      <% end %>
    </div>
    """
  end

  # ── UPM tab ─────────────────────────────────────────────────────────

  defp render_tray_tab(%{tray_tab: "upm"} = assigns) do
    ~H"""
    <div class="space-y-1">
      <div :if={@tray_upm_agents == []} class="text-xs text-base-content/40 py-4 text-center">
        No UPM formation context active
      </div>
      <div
        :for={agent <- @tray_upm_agents}
        class="flex items-center gap-2 text-xs font-mono bg-base-300/50 rounded px-2 py-1"
      >
        <span class="badge badge-xs badge-info">{Map.get(agent, :formation_role, "?")}</span>
        <span class="text-base-content/70 w-28 truncate">{Map.get(agent, :agent_id, "?")}</span>
        <span class="text-base-content/50 flex-1 truncate">{Map.get(agent, :task_subject, "-")}</span>
        <span class="text-base-content/30">wave {Map.get(agent, :wave, "-")}</span>
      </div>
    </div>
    """
  end

  # ── Formation tab ───────────────────────────────────────────────────

  defp render_tray_tab(%{tray_tab: "formation"} = assigns) do
    ~H"""
    <div class="space-y-1">
      <div :if={@tray_formation_agents == []} class="text-xs text-base-content/40 py-4 text-center">
        No formation hierarchy active
      </div>
      <div
        :for={agent <- @tray_formation_agents}
        class="flex items-center gap-2 text-xs font-mono bg-base-300/50 rounded px-2 py-1"
      >
        <span class="badge badge-xs badge-warning">{Map.get(agent, :formation_role, "?")}</span>
        <span class="text-base-content/70 w-28 truncate">{Map.get(agent, :agent_id, "?")}</span>
        <span class="text-base-content/40 w-24 truncate">fid:{Map.get(agent, :formation_id, "?")}</span>
        <span class="text-base-content/50 flex-1 truncate">{Map.get(agent, :task_subject, "-")}</span>
        <span :if={Map.get(agent, :parent_agent_id)} class="text-base-content/30 truncate">
          parent:{Map.get(agent, :parent_agent_id)}
        </span>
      </div>
    </div>
    """
  end

  # ── Memory tab ──────────────────────────────────────────────────────

  defp render_tray_tab(%{tray_tab: "memory"} = assigns) do
    ~H"""
    <div class="space-y-1">
      <div :if={MapSet.size(@selected_conversations) == 0} class="text-xs text-base-content/40 py-4 text-center">
        Select a conversation to view correlated memory observations
      </div>
      <div :if={MapSet.size(@selected_conversations) > 0 && @memory_observations == []} class="text-xs text-base-content/40 py-4 text-center">
        No memory observations correlated with selected session(s)
      </div>
      <div :if={@memory_observations != []} class="space-y-1">
        <p class="text-xs text-base-content/40 mb-2">
          {length(@memory_observations)} observation(s) correlated with selected session(s)
        </p>
        <.link
          :for={obs <- @memory_observations}
          navigate={"/memory"}
          class="flex items-start gap-2 text-xs font-mono bg-base-300/50 hover:bg-base-300 rounded px-2 py-1.5 transition-colors cursor-pointer"
        >
          <span class={[
            "badge badge-xs shrink-0 mt-0.5",
            observation_type_color(obs["observation_type"] || obs[:observation_type])
          ]}>
            {obs["observation_type"] || obs[:observation_type] || "unknown"}
          </span>
          <span class="text-base-content/30 shrink-0 w-16">
            {format_obs_ts(obs["timestamp"] || obs[:timestamp])}
          </span>
          <span class="text-base-content/70 flex-1 truncate">
            {truncate(obs["narrative"] || obs[:narrative] || "(no content)", 160)}
          </span>
        </.link>
      </div>
    </div>
    """
  end

  defp render_tray_tab(assigns) do
    ~H"""
    <div class="text-xs text-base-content/40 py-4 text-center">
      Unknown tab
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp extract_tool_entries(messages) do
    messages
    |> Enum.flat_map(fn msg ->
      calls =
        Enum.map(msg.tool_calls, fn tc ->
          %{
            type: "tool_use",
            name: tc.name,
            preview: tc.input_preview || "",
            timestamp: msg.timestamp,
            is_error: false
          }
        end)

      results =
        Enum.map(msg.tool_results, fn tr ->
          %{
            type: "tool_result",
            name: nil,
            preview: tr.content_preview || "",
            timestamp: msg.timestamp,
            is_error: tr.is_error
          }
        end)

      calls ++ results
    end)
  end

  defp build_execution_timeline(messages) do
    messages
    |> Enum.filter(fn m -> m.type in ["user", "assistant"] end)
    |> Enum.map(fn m ->
      %{
        type: m.type,
        timestamp: m.timestamp,
        content: m.content,
        usage: m.usage,
        tool_calls: m.tool_calls
      }
    end)
  end

  defp truncate(nil, _max), do: ""
  defp truncate(text, max) when byte_size(text) <= max, do: text
  defp truncate(text, max), do: String.slice(text, 0, max) <> "..."

  defp format_dt(nil), do: "?"
  defp format_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%m/%d %H:%M:%S")
  defp format_dt(_), do: "?"

  defp observation_type_color("agent"), do: "badge-primary"
  defp observation_type_color("tool_call"), do: "badge-info"
  defp observation_type_color("session"), do: "badge-secondary"
  defp observation_type_color("error"), do: "badge-error"
  defp observation_type_color("security"), do: "badge-warning"
  defp observation_type_color("memory"), do: "badge-accent"
  defp observation_type_color(_), do: "badge-ghost"

  defp format_obs_ts(nil), do: "?"

  defp format_obs_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> String.slice(ts, 11, 8)
    end
  end

  defp format_obs_ts(_), do: "?"

  defp format_ts(nil), do: "?"

  defp format_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> String.slice(ts, 11, 8)
    end
  end

  defp format_ts(_), do: "?"

  # Relative timestamp — "Xm ago", "Xs ago", or falls back to absolute.
  defp relative_ts(nil), do: "?"

  defp relative_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)

        cond do
          diff < 60 -> "#{diff}s ago"
          diff < 3600 -> "#{div(diff, 60)}m ago"
          diff < 86_400 -> "#{div(diff, 3600)}h ago"
          true -> Calendar.strftime(dt, "%m/%d")
        end

      _ ->
        format_ts(ts)
    end
  end

  defp relative_ts(_), do: "?"
end
