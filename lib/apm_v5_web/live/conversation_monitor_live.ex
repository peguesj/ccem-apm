defmodule ApmV5Web.ConversationMonitorLive do
  @moduledoc """
  Observe — Conversations LiveView (CP-181 / US-456).

  Redesigned using the CCEM design system components. Displays all Claude Code
  conversation sessions sourced from `ConversationWatcher` in a two-column layout:

  - Left (40%): filterable `<.data_table>` listing sessions with Session ID,
    Project, Size, Status, and Last Active columns.
  - Right (60%): live transcript panel rendering the selected session's messages
    via `<.streaming_text>` per message, with a `<.skeleton>` shimmer while
    loading.

  The right inspector panel shows per-message detail for a selected message.

  PubSub: subscribes to `"apm:conversations"` for live conversation list updates.
  Live polling at 3-second intervals refreshes the transcript of the selected session.
  """

  use ApmV5Web, :live_view

  require Logger

  @pubsub_topic "apm:conversations"
  @live_poll_ms 3_000

  # ---------------------------------------------------------------------------
  # mount/3
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic)
    end

    conversations = load_conversations()

    {:ok,
     socket
     |> assign(
       page_title: "Conversations",
       view_mode: "Live",
       sidebar_collapsed: false,
       inspector_open: false,
       inspector_mode: "selection",
       selected_session: nil,
       filter_query: "",
       conversations: conversations,
       messages: [],
       messages_loading: false,
       live_offset: 0,
       selected_message: nil
     )
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  # ---------------------------------------------------------------------------
  # handle_info/2
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:conversations_updated, conversations}, socket) do
    {:noreply, assign(socket, conversations: conversations)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, conversations: load_conversations())}
  end

  @impl true
  def handle_info(:poll_live, socket) do
    socket =
      if socket.assigns.selected_session && socket.assigns.view_mode == "Live" do
        Process.send_after(self(), :poll_live, @live_poll_ms)
        poll_live_messages(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # handle_event/3
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("select_session", %{"path" => path}, socket) do
    {messages, offset} = load_messages(path)

    socket =
      socket
      |> assign(
        selected_session: path,
        messages: messages,
        messages_loading: false,
        live_offset: offset,
        selected_message: nil
      )
      |> maybe_start_poll()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_conversations", %{"value" => query}, socket) do
    {:noreply, assign(socket, filter_query: query)}
  end

  @impl true
  def handle_event("switch_view_mode", %{"value" => mode}, socket) do
    socket = assign(socket, view_mode: mode)

    socket =
      if mode == "Live" && socket.assigns.selected_session do
        Process.send_after(self(), :poll_live, @live_poll_ms)
        socket
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_collapsed: !socket.assigns.sidebar_collapsed)}
  end

  @impl true
  def handle_event("toggle_inspector", _params, socket) do
    {:noreply, assign(socket, inspector_open: !socket.assigns.inspector_open)}
  end

  @impl true
  def handle_event("inspector_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, inspector_mode: mode)}
  end

  @impl true
  def handle_event("select_message", %{"index" => raw_index}, socket) do
    index = raw_index |> to_string() |> Integer.parse() |> elem(0)
    selected = Enum.at(socket.assigns.messages, index)

    {:noreply,
     assign(socket,
       selected_message: selected,
       inspector_open: true,
       inspector_mode: "selection"
     )}
  end

  # ---------------------------------------------------------------------------
  # render/1
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :filtered_conversations, filter_conversations(assigns))

    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav current_path="/conversations" />
      </:sidebar>

      <:topbar>
        <.top_bar project_name="CCEM APM" />
      </:topbar>

      <:main>
        <%!-- Page header --%>
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
          <div style="display: flex; align-items: baseline; gap: 10px;">
            <h1 style="margin: 0; font-size: 16px; font-weight: 600; color: var(--ccem-fg);">
              Conversations
            </h1>
            <span style="font-size: 12px; color: var(--ccem-fg-dim);">
              {length(@filtered_conversations)} of {length(@conversations)} sessions
            </span>
          </div>
          <div style="display: flex; align-items: center; gap: 8px;">
            <.badge :if={count_active(@conversations) > 0} tone="ok" dot>
              {count_active(@conversations)} live
            </.badge>
            <.badge :if={count_active(@conversations) == 0} tone="neutral">
              idle
            </.badge>
            <button
              phx-click="toggle_inspector"
              style="display: flex; align-items: center; justify-content: center; width: 28px; height: 28px; background: var(--ccem-bg-2); border: 1px solid var(--ccem-line); border-radius: 5px; cursor: pointer; color: var(--ccem-fg-dim); font-size: 13px;"
              title="Toggle inspector"
            >
              &#9776;
            </button>
          </div>
        </div>

        <%!-- Stat tiles --%>
        <div style="display: flex; gap: 12px; margin-bottom: 16px; flex-wrap: wrap;">
          <.card style="flex: 1; min-width: 110px; padding: 12px 16px;">
            <.stat_tile label="Total" value={to_string(length(@conversations))} />
          </.card>
          <.card style="flex: 1; min-width: 110px; padding: 12px 16px;">
            <.stat_tile label="Active" value={to_string(count_active(@conversations))} />
          </.card>
          <.card style="flex: 1; min-width: 110px; padding: 12px 16px;">
            <.stat_tile label="Idle" value={to_string(count_idle(@conversations))} />
          </.card>
          <.card style="flex: 1; min-width: 110px; padding: 12px 16px;">
            <.stat_tile
              label="Selected"
              value={if @selected_session, do: "1", else: "—"}
            />
          </.card>
        </div>

        <%!-- Filter bar --%>
        <div style="display: flex; align-items: center; gap: 10px; margin-bottom: 16px; flex-wrap: wrap;">
          <div style="flex: 1; min-width: 180px; max-width: 360px;">
            <.ds_input
              type="search"
              placeholder="Filter conversations..."
              value={@filter_query}
              phx-change="filter_conversations"
              phx-debounce="200"
              name="value"
            />
          </div>
          <.segmented_control
            options={["Live", "History"]}
            active={@view_mode}
            on_change="switch_view_mode"
          />
        </div>

        <%!-- Two-column split: 40% list | 60% transcript --%>
        <div style="display: grid; grid-template-columns: 40% 1fr; gap: 16px; min-height: 0;">

          <%!-- Left: Conversation list --%>
          <.card padded={false}>
            <div style="padding: 10px 12px; border-bottom: 1px solid var(--ccem-line-subtle, var(--ccem-line));">
              <span style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-dim);">
                Sessions
              </span>
            </div>
            <div :if={@filtered_conversations == []} style="padding: 32px 16px; text-align: center; color: var(--ccem-fg-dim); font-size: 13px;">
              No sessions found in ~/.claude/projects/
            </div>
            <.data_table
              :if={@filtered_conversations != []}
              id="conversations-table"
              rows={@filtered_conversations}
            >
              <:col :let={conv} label="Session">
                <button
                  phx-click="select_session"
                  phx-value-path={conversation_path(conv)}
                  style={
                    "background: none; border: none; cursor: pointer; text-align: left; " <>
                      "font-family: var(--ccem-font-mono, monospace); font-size: 11px; " <>
                      "color: #{if selected_session?(conv, @selected_session), do: "var(--ccem-accent)", else: "var(--ccem-fg)"}; " <>
                      "padding: 0; max-width: 120px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; display: block;"
                  }
                  title={conv.session_id}
                >
                  {truncate(conv.session_id, 14)}
                </button>
              </:col>
              <:col :let={conv} label="Project">
                <span style="font-size: 12px; color: var(--ccem-fg); max-width: 100px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; display: inline-block;" title={conv.project}>
                  {truncate(conv.project, 16)}
                </span>
              </:col>
              <:col :let={conv} label="Size">
                <span style="font-size: 11px; font-family: var(--ccem-font-mono, monospace); color: var(--ccem-fg-dim);">
                  {format_bytes(conv.size_bytes)}
                </span>
              </:col>
              <:col :let={conv} label="Status">
                <.badge tone={if conv.active, do: "ok", else: "neutral"} dot={conv.active}>
                  {if conv.active, do: "active", else: "idle #{conv.idle_minutes}m"}
                </.badge>
              </:col>
              <:col :let={conv} label="Last Active">
                <span style="font-size: 11px; color: var(--ccem-fg-dim); white-space: nowrap;">
                  {format_dt(conv.last_modified)}
                </span>
              </:col>
            </.data_table>
          </.card>

          <%!-- Right: Transcript panel --%>
          <.card padded={false} style="display: flex; flex-direction: column; overflow: hidden; min-height: 320px;">
            <%!-- Transcript header --%>
            <div style="padding: 10px 12px; border-bottom: 1px solid var(--ccem-line-subtle, var(--ccem-line)); display: flex; align-items: center; justify-content: space-between; flex-shrink: 0;">
              <span style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-dim);">
                Transcript
              </span>
              <span :if={@selected_session} style="font-family: var(--ccem-font-mono, monospace); font-size: 10px; color: var(--ccem-fg-muted);">
                {Path.basename(@selected_session)}
              </span>
            </div>

            <%!-- Transcript body --%>
            <div
              id="transcript-scroll"
              style="flex: 1; overflow-y: auto; padding: 12px; display: flex; flex-direction: column; gap: 8px;"
            >
              <%!-- Empty state --%>
              <div :if={is_nil(@selected_session)} style="display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100%; color: var(--ccem-fg-dim); text-align: center; padding: 24px;">
                <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" fill="none" viewBox="0 0 24 24" stroke="currentColor" style="opacity: 0.3; margin-bottom: 10px;">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z" />
                </svg>
                <p style="font-size: 13px; font-weight: 500; margin: 0 0 4px;">No session selected</p>
                <p style="font-size: 12px; margin: 0; opacity: 0.6;">Click a row in the session list to view its transcript.</p>
              </div>

              <%!-- Loading shimmer --%>
              <.skeleton :if={@messages_loading} lines={5} />

              <%!-- Messages --%>
              <%= if !is_nil(@selected_session) && !@messages_loading do %>
                <div :if={@messages == []} style="color: var(--ccem-fg-dim); font-size: 13px; text-align: center; padding: 24px 0;">
                  No messages found in this session.
                </div>

                <div
                  :for={{msg, idx} <- Enum.with_index(@messages)}
                  id={"msg-#{idx}"}
                  phx-click="select_message"
                  phx-value-index={idx}
                  style={
                    "display: flex; flex-direction: column; gap: 4px; " <>
                      "padding: 8px 10px; border-radius: 6px; cursor: pointer; " <>
                      "border-left: 3px solid #{msg_border_color(msg.type)}; " <>
                      "background: #{msg_bg_color(msg.type)}; " <>
                      "transition: background 120ms;"
                  }
                >
                  <div style="display: flex; align-items: center; gap: 8px;">
                    <.badge tone={msg_badge_tone(msg.type)}>
                      {msg.type}
                    </.badge>
                    <span style="font-size: 10px; font-family: var(--ccem-font-mono, monospace); color: var(--ccem-fg-dim);">
                      {format_ts(msg.timestamp)}
                    </span>
                    <span :if={length(msg.tool_calls) > 0} style="font-size: 10px; color: var(--ccem-info, #3b82f6);">
                      {length(msg.tool_calls)} tool call(s)
                    </span>
                  </div>
                  <.streaming_text
                    text={truncate(msg.content || "(no text content)", 300)}
                    streaming={msg.type == "assistant" && @view_mode == "Live"}
                  />
                </div>
              <% end %>
            </div>
          </.card>

        </div>
      </:main>

      <:inspector>
        <.inspector_panel open={@inspector_open} mode={@inspector_mode} on_close="toggle_inspector">
          <:selection>
            {render_message_detail(assigns)}
          </:selection>
          <:copilot>
            <div style="color: var(--ccem-fg-dim); font-size: 13px; padding: 8px 0;">
              Select a message in the transcript to view its detail here.
            </div>
          </:copilot>
          <:filters>
            <div style="display: flex; flex-direction: column; gap: 12px;">
              <div>
                <p style="margin: 0 0 6px; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-dim);">View Mode</p>
                <.segmented_control
                  options={["Live", "History"]}
                  active={@view_mode}
                  on_change="switch_view_mode"
                />
              </div>
              <div>
                <p style="margin: 0 0 6px; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-dim);">Filter</p>
                <.ds_input
                  type="search"
                  placeholder="Filter conversations..."
                  value={@filter_query}
                  phx-change="filter_conversations"
                  phx-debounce="200"
                  name="value"
                />
              </div>
            </div>
          </:filters>
        </.inspector_panel>
      </:inspector>
    </.page_layout>
    """
  end

  # ---------------------------------------------------------------------------
  # Private: render helpers
  # ---------------------------------------------------------------------------

  defp render_message_detail(%{selected_message: nil} = assigns) do
    ~H"""
    <div style="color: var(--ccem-fg-dim); font-size: 13px; padding: 8px 0;">
      Click a message in the transcript to inspect it here.
    </div>
    """
  end

  defp render_message_detail(%{selected_message: msg} = assigns) do
    assigns = assign(assigns, :msg, msg)

    ~H"""
    <div style="display: flex; flex-direction: column; gap: 10px;">
      <div style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap;">
        <.badge tone={msg_badge_tone(@msg.type)}>{@msg.type}</.badge>
        <span style="font-size: 10px; font-family: var(--ccem-font-mono, monospace); color: var(--ccem-fg-dim);">
          {format_ts(@msg.timestamp)}
        </span>
      </div>

      <%!-- Token usage --%>
      <%= if @msg.usage do %>
        <div style="display: flex; gap: 8px; flex-wrap: wrap;">
          <.stat_tile label="Input Tok" value={to_string(@msg.usage.input_tokens)} />
          <.stat_tile label="Output Tok" value={to_string(@msg.usage.output_tokens)} />
        </div>
      <% end %>

      <%!-- Tool calls --%>
      <%= if length(@msg.tool_calls) > 0 do %>
        <div>
          <p style="margin: 0 0 6px; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-dim);">
            Tool Calls
          </p>
          <div style="display: flex; flex-direction: column; gap: 4px;">
            <div
              :for={tc <- @msg.tool_calls}
              style="display: flex; align-items: center; gap: 6px; padding: 4px 8px; background: var(--ccem-bg-2); border-radius: 4px;"
            >
              <.badge tone="info">{tc.name}</.badge>
              <span style="font-size: 11px; color: var(--ccem-fg-dim); font-family: var(--ccem-font-mono, monospace); flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                {tc.input_preview || ""}
              </span>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Full message content --%>
      <div>
        <p style="margin: 0 0 6px; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-dim);">
          Content
        </p>
        <div style="background: var(--ccem-bg-2); border-radius: 6px; padding: 10px; max-height: 300px; overflow-y: auto;">
          <.streaming_text text={@msg.content || "(no text content)"} streaming={false} />
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private: data loading
  # ---------------------------------------------------------------------------

  @spec load_conversations() :: list(map())
  defp load_conversations do
    ApmV5.ConversationWatcher.get_conversations()
  end

  @spec load_messages(String.t()) :: {list(map()), non_neg_integer()}
  defp load_messages(path) do
    case ApmV5.ConversationReader.read_recent(path, 100) do
      {:ok, messages} ->
        offset =
          case ApmV5.ConversationReader.file_size(path) do
            {:ok, size} -> size
            _ -> 0
          end

        {messages, offset}

      _ ->
        {[], 0}
    end
  end

  @spec poll_live_messages(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp poll_live_messages(%{assigns: %{selected_session: nil}} = socket), do: socket

  defp poll_live_messages(socket) do
    path = socket.assigns.selected_session
    offset = socket.assigns.live_offset

    case ApmV5.ConversationReader.read_from_offset(path, offset) do
      {:ok, new_messages, new_offset} when new_messages != [] ->
        existing = socket.assigns.messages
        # Keep last 200 messages total
        combined = (existing ++ new_messages) |> Enum.take(-200)
        assign(socket, messages: combined, live_offset: new_offset)

      {:ok, [], _new_offset} ->
        socket

      _ ->
        socket
    end
  end

  @spec maybe_start_poll(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp maybe_start_poll(socket) do
    if socket.assigns.view_mode == "Live" && socket.assigns.selected_session do
      Process.send_after(self(), :poll_live, @live_poll_ms)
    end

    socket
  end

  # ---------------------------------------------------------------------------
  # Private: filtering
  # ---------------------------------------------------------------------------

  @spec filter_conversations(map()) :: list(map())
  defp filter_conversations(%{conversations: convs, filter_query: ""}) do
    Enum.sort_by(convs, & &1.last_modified, {:desc, NaiveDateTime})
  end

  defp filter_conversations(%{conversations: convs, filter_query: query}) do
    q = String.downcase(query)

    convs
    |> Enum.filter(fn conv ->
      String.contains?(String.downcase(conv.session_id), q) or
        String.contains?(String.downcase(conv.project), q)
    end)
    |> Enum.sort_by(& &1.last_modified, {:desc, NaiveDateTime})
  end

  # ---------------------------------------------------------------------------
  # Private: path resolution
  # ---------------------------------------------------------------------------

  @spec conversation_path(map()) :: String.t() | nil
  defp conversation_path(conv) do
    projects_dir = Path.expand("~/.claude/projects")
    find_jsonl_path(projects_dir, conv.file)
  end

  @spec find_jsonl_path(String.t(), String.t()) :: String.t() | nil
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

  # ---------------------------------------------------------------------------
  # Private: display helpers
  # ---------------------------------------------------------------------------

  @spec selected_session?(map(), String.t() | nil) :: boolean()
  defp selected_session?(_conv, nil), do: false

  defp selected_session?(conv, selected) do
    conversation_path(conv) == selected
  end

  @spec count_active(list(map())) :: non_neg_integer()
  defp count_active(conversations), do: Enum.count(conversations, & &1.active)

  @spec count_idle(list(map())) :: non_neg_integer()
  defp count_idle(conversations), do: Enum.count(conversations, &(!&1.active))

  @spec format_bytes(non_neg_integer()) :: String.t()
  defp format_bytes(b) when b < 1_024, do: "#{b}B"
  defp format_bytes(b) when b < 1_048_576, do: "#{div(b, 1_024)}KB"
  defp format_bytes(b), do: "#{Float.round(b / 1_048_576, 1)}MB"

  @spec format_dt(NaiveDateTime.t() | nil) :: String.t()
  defp format_dt(nil), do: "—"
  defp format_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%m/%d %H:%M")
  defp format_dt(_), do: "—"

  @spec format_ts(String.t() | nil) :: String.t()
  defp format_ts(nil), do: "—"

  defp format_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> String.slice(ts, 11, 8)
    end
  end

  defp format_ts(_), do: "—"

  @spec truncate(String.t() | nil, non_neg_integer()) :: String.t()
  defp truncate(nil, _max), do: ""
  defp truncate(text, max) when byte_size(text) <= max, do: text
  defp truncate(text, max), do: String.slice(text, 0, max) <> "…"

  @spec msg_border_color(String.t()) :: String.t()
  defp msg_border_color("user"), do: "var(--ccem-iris, #7c6cf8)"
  defp msg_border_color("assistant"), do: "var(--ccem-ok, #22c55e)"
  defp msg_border_color("system"), do: "var(--ccem-warn, #f59e0b)"
  defp msg_border_color(_), do: "var(--ccem-line)"

  @spec msg_bg_color(String.t()) :: String.t()
  defp msg_bg_color("user"),
    do: "color-mix(in srgb, var(--ccem-iris, #7c6cf8) 8%, transparent)"

  defp msg_bg_color("assistant"),
    do: "color-mix(in srgb, var(--ccem-ok, #22c55e) 6%, transparent)"

  defp msg_bg_color("system"),
    do: "color-mix(in srgb, var(--ccem-warn, #f59e0b) 8%, transparent)"

  defp msg_bg_color(_), do: "var(--ccem-bg-2)"

  @spec msg_badge_tone(String.t()) :: String.t()
  defp msg_badge_tone("user"), do: "iris"
  defp msg_badge_tone("assistant"), do: "ok"
  defp msg_badge_tone("system"), do: "warn"
  defp msg_badge_tone(_), do: "neutral"
end
