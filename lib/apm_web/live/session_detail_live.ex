defmodule ApmWeb.SessionDetailLive do
  @moduledoc """
  Observe — Session Detail LiveView (CP-177 / US-452).

  Renders a focused per-session inspector using the CCEM design system shell:

  - Three-zone `page_layout` (sidebar | main | inspector)
  - `top_bar` with CCEM APM branding
  - `segmented_control` tab switcher: Transcript | Tool Calls | Tokens
  - **Transcript tab**: `streaming_text` per message, role-labelled with `badge`
  - **Tool Calls tab**: `data_table` with Tool / Status / Duration / Tokens columns
  - **Tokens tab**: three `stat_tile`s (input / output / cache) + a breakdown `card`
  - Right `inspector_panel` with selected tool call detail in the `:selection` slot

  Navigation slots:

      /observe/sessions/:session_id

  where `:session_id` is the UUID stem of the `.jsonl` file under
  `~/.claude/projects/`.

  ## Live updates
  The LiveView subscribes to `"apm:conversations"` PubSub and polls for new JSONL
  lines every 3 seconds while the Transcript tab is active, keeping the transcript
  scroll-locked to the bottom.
  """

  use ApmWeb, :live_view

  import ApmWeb.Components.SidebarNav

  alias Apm.ConversationWatcher
  alias Apm.ConversationReader

  require Logger

  @pubsub_topic "apm:conversations"
  @poll_interval_ms 3_000

  # ---------------------------------------------------------------------------
  # mount/3
  # ---------------------------------------------------------------------------

  @impl true
  def mount(%{"session_id" => session_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Apm.PubSub, @pubsub_topic)
    end

    socket =
      socket
      |> assign(
        page_title: "Session Detail",
        session_id: session_id,
        tab: "Transcript",
        sidebar_collapsed: false,
        inspector_open: false,
        inspector_mode: "selection",
        selected_tool_call: nil,
        messages: [],
        tool_calls: [],
        token_stats: %{input: 0, output: 0, cache_read: 0, cache_creation: 0},
        live_offset: 0,
        loading: true
      )
      |> assign_sidebar_nav_data()
      |> load_session()

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # handle_params/3 — tab switching via URL param
  # ---------------------------------------------------------------------------

  @impl true
  def handle_params(params, _uri, socket) do
    tab = params["tab"] || socket.assigns.tab
    {:noreply, assign(socket, tab: tab)}
  end

  # ---------------------------------------------------------------------------
  # handle_event/3
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("set_tab", %{"value" => tab}, socket) do
    socket = assign(socket, tab: tab)

    socket =
      if tab == "Transcript" and socket.assigns.inspector_open do
        socket
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_tool_call", %{"id" => id}, socket) do
    selected =
      Enum.find(socket.assigns.tool_calls, fn tc -> to_string(tc.id) == id end)

    {:noreply,
     assign(socket,
       selected_tool_call: selected,
       inspector_open: true,
       inspector_mode: "selection"
     )}
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
  def handle_event("refresh", _params, socket) do
    {:noreply, load_session(socket)}
  end

  # ---------------------------------------------------------------------------
  # handle_info/2
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:conversations_updated, _conversations}, socket) do
    {:noreply, load_session(socket)}
  end

  @impl true
  def handle_info(:poll_live, socket) do
    socket =
      if socket.assigns.tab == "Transcript" do
        poll_new_messages(socket)
      else
        socket
      end

    if connected?(socket) do
      Process.send_after(self(), :poll_live, @poll_interval_ms)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # render/1
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout
      sidebar_collapsed={@sidebar_collapsed}
      inspector_open={@inspector_open}
      inspector_mode={@inspector_mode}
    >
      <:sidebar>
        <.sidebar_nav current_path="/conversations" />
      </:sidebar>

      <:topbar>
        <.top_bar project_name="CCEM APM" />
      </:topbar>

      <:main>
        <div style="display: flex; flex-direction: column; gap: 16px; min-height: 100%;">
          <%!-- Session header --%>
          <.card>
            <div style="display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; flex-wrap: wrap;">
              <div style="min-width: 0;">
                <div style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap; margin-bottom: 4px;">
                  <span style="font-size: 14px; font-weight: 600; color: var(--ccem-fg);">
                    {session_project_name(@session_meta)}
                  </span>
                  <.badge tone={status_tone(@session_meta)} dot={session_active?(@session_meta)}>
                    {session_status_label(@session_meta)}
                  </.badge>
                  <span style="font-size: 12px; color: var(--ccem-fg-dim);">
                    {session_duration(@session_meta)}
                  </span>
                </div>
                <div style="font-family: var(--ccem-font-mono, monospace); font-size: 11px; color: var(--ccem-fg-dim); word-break: break-all;">
                  {@session_id}
                </div>
              </div>

              <div style="display: flex; align-items: center; gap: 8px; flex-shrink: 0;">
                <.kbd key="j" /> / <.kbd key="k" />
                <span style="font-size: 11px; color: var(--ccem-fg-dim);">navigate</span>

                <button
                  phx-click="toggle_inspector"
                  style={inspector_btn_style(@inspector_open)}
                  title="Toggle inspector panel"
                >
                  Inspector
                </button>

                <button
                  phx-click="refresh"
                  style={
                    "height: 28px; padding: 0 10px; background: var(--ccem-bg-2); " <>
                    "border: 1px solid var(--ccem-line); border-radius: 5px; " <>
                    "font-size: 12px; color: var(--ccem-fg); cursor: pointer;"
                  }
                >
                  Refresh
                </button>
              </div>
            </div>
          </.card>

          <%!-- Tab switcher --%>
          <div style="display: flex; align-items: center; gap: 12px;">
            <.segmented_control
              options={["Transcript", "Tool Calls", "Tokens"]}
              active={@tab}
              on_change="set_tab"
            />
            <span style="font-size: 12px; color: var(--ccem-fg-dim);">
              {tab_summary_label(assigns)}
            </span>
          </div>

          <%!-- Tab content --%>
          {render_tab(assigns)}
        </div>
      </:main>

      <:inspector>
        <.inspector_panel open={@inspector_open} mode={@inspector_mode} on_close="toggle_inspector">
          <:selection>
            {render_inspector_selection(assigns)}
          </:selection>
        </.inspector_panel>
      </:inspector>
    </.page_layout>
    """
  end

  # ---------------------------------------------------------------------------
  # Private: tab rendering
  # ---------------------------------------------------------------------------

  defp render_tab(%{tab: "Transcript"} = assigns) do
    ~H"""
    <div id="session-transcript" style="display: flex; flex-direction: column; gap: 8px;">
      <div :if={@loading}>
        <.skeleton lines={6} />
      </div>

      <div
        :if={!@loading and @messages == []}
        style="text-align: center; padding: 48px 0; color: var(--ccem-fg-dim); font-size: 13px;"
      >
        No messages found for this session.
      </div>

      <div
        :for={msg <- @messages}
        style={message_row_style(msg.type)}
      >
        <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 4px;">
          <.badge tone={role_tone(msg.type)}>
            {role_label(msg.type)}
          </.badge>
          <span style="font-family: var(--ccem-font-mono, monospace); font-size: 11px; color: var(--ccem-fg-dim);">
            {format_ts(msg.timestamp)}
          </span>
          <span
            :if={length(msg.tool_calls) > 0}
            style="font-size: 11px; color: var(--ccem-iris, #7c6cf8);"
          >
            {length(msg.tool_calls)} tool call(s)
          </span>
          <span
            :if={msg.usage}
            style="font-size: 11px; color: var(--ccem-fg-dim); margin-left: auto;"
          >
            {format_usage_inline(msg.usage)}
          </span>
        </div>

        <.streaming_text
          :if={msg.content}
          text={msg.content}
          streaming={false}
        />

        <%!-- Tool call chips --%>
        <div
          :if={length(msg.tool_calls) > 0}
          style="display: flex; flex-wrap: wrap; gap: 4px; margin-top: 6px;"
        >
          <button
            :for={tc <- msg.tool_calls}
            phx-click="select_tool_call"
            phx-value-id={tc.id}
            style={tool_chip_style()}
          >
            {tc.name}
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp render_tab(%{tab: "Tool Calls"} = assigns) do
    ~H"""
    <div>
      <div :if={@loading}>
        <.skeleton lines={4} />
      </div>

      <div
        :if={!@loading and @tool_calls == []}
        style="text-align: center; padding: 48px 0; color: var(--ccem-fg-dim); font-size: 13px;"
      >
        No tool calls recorded for this session.
      </div>

      <.data_table :if={@tool_calls != []} id="session-tool-calls" rows={@tool_calls}>
        <:col :let={tc} label="Tool">
          <span style="font-family: var(--ccem-font-mono, monospace); font-size: 12px;">
            {tc.name}
          </span>
        </:col>
        <:col :let={tc} label="Status">
          <.badge tone={tc_status_tone(tc)}>
            {tc_status_label(tc)}
          </.badge>
        </:col>
        <:col :let={tc} label="Tokens">
          <span style="font-family: var(--ccem-font-mono, monospace); font-size: 12px; color: var(--ccem-fg-dim);">
            {tc_tokens(tc)}
          </span>
        </:col>
        <:col :let={tc} label="">
          <button
            phx-click="select_tool_call"
            phx-value-id={tc.id}
            style={
              "height: 24px; padding: 0 8px; background: var(--ccem-bg-2); " <>
              "border: 1px solid var(--ccem-line); border-radius: 4px; " <>
              "font-size: 11px; color: var(--ccem-fg); cursor: pointer;"
            }
          >
            Inspect
          </button>
        </:col>
      </.data_table>
    </div>
    """
  end

  defp render_tab(%{tab: "Tokens"} = assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; gap: 16px;">
      <div :if={@loading}>
        <.skeleton lines={3} />
      </div>

      <div :if={!@loading} style="display: flex; gap: 16px; flex-wrap: wrap;">
        <.card style="flex: 1; min-width: 140px;">
          <.stat_tile
            label="Input Tokens"
            value={format_tokens(@token_stats.input)}
          />
        </.card>
        <.card style="flex: 1; min-width: 140px;">
          <.stat_tile
            label="Output Tokens"
            value={format_tokens(@token_stats.output)}
          />
        </.card>
        <.card style="flex: 1; min-width: 140px;">
          <.stat_tile
            label="Cache Read"
            value={format_tokens(@token_stats.cache_read)}
          />
        </.card>
        <.card style="flex: 1; min-width: 140px;">
          <.stat_tile
            label="Cache Written"
            value={format_tokens(@token_stats.cache_creation)}
          />
        </.card>
      </div>

      <.card :if={!@loading}>
        <div style="font-size: 11px; font-weight: 600; letter-spacing: 0.07em; text-transform: uppercase; color: var(--ccem-fg-dim); margin-bottom: 12px;">
          Token Breakdown
        </div>
        <div style="display: flex; flex-direction: column; gap: 8px;">
          <.token_row
            label="Total Input"
            value={@token_stats.input}
            total={token_total(@token_stats)}
          />
          <.token_row
            label="Total Output"
            value={@token_stats.output}
            total={token_total(@token_stats)}
          />
          <.token_row
            label="Cache Reads"
            value={@token_stats.cache_read}
            total={token_total(@token_stats)}
          />
          <.token_row
            label="Cache Writes"
            value={@token_stats.cache_creation}
            total={token_total(@token_stats)}
          />
        </div>
        <div style="margin-top: 12px; padding-top: 12px; border-top: 1px solid var(--ccem-line-subtle);">
          <div style="display: flex; justify-content: space-between; font-size: 13px;">
            <span style="color: var(--ccem-fg-dim);">Grand Total</span>
            <span style="font-weight: 600; font-variant-numeric: tabular-nums; color: var(--ccem-fg);">
              {format_tokens(token_total(@token_stats))}
            </span>
          </div>
          <div
            :if={@messages != []}
            style="margin-top: 4px; font-size: 11px; color: var(--ccem-fg-dim);"
          >
            across {length(@messages)} message(s) · {length(@tool_calls)} tool call(s)
          </div>
        </div>
      </.card>
    </div>
    """
  end

  defp render_tab(assigns) do
    ~H"""
    <div style="color: var(--ccem-fg-dim); font-size: 13px; padding: 32px 0; text-align: center;">
      Unknown tab
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private: inspector selection panel
  # ---------------------------------------------------------------------------

  defp render_inspector_selection(%{selected_tool_call: nil} = assigns) do
    ~H"""
    <div style="font-size: 13px; color: var(--ccem-fg-dim); padding: 24px 0; text-align: center;">
      Select a tool call to inspect
    </div>
    """
  end

  defp render_inspector_selection(%{selected_tool_call: _tc} = assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; gap: 12px;">
      <div>
        <div style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-dim); margin-bottom: 4px;">
          Tool
        </div>
        <div style="font-family: var(--ccem-font-mono, monospace); font-size: 13px; color: var(--ccem-fg);">
          {@selected_tool_call.name}
        </div>
      </div>

      <div>
        <div style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-dim); margin-bottom: 4px;">
          Status
        </div>
        <.badge tone={tc_status_tone(@selected_tool_call)}>
          {tc_status_label(@selected_tool_call)}
        </.badge>
      </div>

      <div :if={@selected_tool_call.input_preview && @selected_tool_call.input_preview != "..."}>
        <div style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-dim); margin-bottom: 4px;">
          Input
        </div>
        <div style={
          "font-family: var(--ccem-font-mono, monospace); font-size: 11px; " <>
          "color: var(--ccem-fg); background: var(--ccem-bg-2); " <>
          "border: 1px solid var(--ccem-line); border-radius: 5px; " <>
          "padding: 8px; white-space: pre-wrap; word-break: break-all; max-height: 200px; overflow-y: auto;"
        }>
          {@selected_tool_call.input_preview}
        </div>
      </div>

      <div>
        <div style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: var(--ccem-fg-dim); margin-bottom: 4px;">
          ID
        </div>
        <div style="font-family: var(--ccem-font-mono, monospace); font-size: 11px; color: var(--ccem-fg-dim); word-break: break-all;">
          {@selected_tool_call.id}
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private: token_row sub-component
  # ---------------------------------------------------------------------------

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :total, :integer, required: true

  defp token_row(assigns) do
    pct =
      if assigns.total > 0,
        do: Float.round(assigns.value / assigns.total * 100, 1),
        else: 0.0

    assigns = assign(assigns, :pct, pct)

    ~H"""
    <div style="display: flex; flex-direction: column; gap: 3px;">
      <div style="display: flex; justify-content: space-between; font-size: 12px;">
        <span style="color: var(--ccem-fg-dim);">{@label}</span>
        <span style="font-variant-numeric: tabular-nums; color: var(--ccem-fg);">
          {format_tokens(@value)}
          <span style="color: var(--ccem-fg-dim); font-size: 11px;"> ({@pct}%)</span>
        </span>
      </div>
      <div style="height: 4px; background: var(--ccem-bg-3); border-radius: 2px; overflow: hidden;">
        <div style={"height: 100%; width: #{@pct}%; background: var(--ccem-accent); border-radius: 2px; transition: width 400ms ease;"} />
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private: data loading
  # ---------------------------------------------------------------------------

  defp load_session(socket) do
    session_id = socket.assigns.session_id
    file_path = resolve_file_path(session_id)

    {messages, token_stats, session_meta} =
      case file_path && ConversationReader.read_recent(file_path, 100) do
        {:ok, msgs} ->
          stats = aggregate_token_stats(msgs)
          meta = build_session_meta(session_id, msgs)
          {msgs, stats, meta}

        _ ->
          {[], empty_token_stats(), nil}
      end

    tool_calls = extract_tool_calls(messages)

    # Initialize live-tail offset
    live_offset =
      case file_path && ConversationReader.file_size(file_path) do
        {:ok, size} -> size
        _ -> 0
      end

    # Start poll cycle on first connection
    if connected?(socket) and socket.assigns.loading do
      Process.send_after(self(), :poll_live, @poll_interval_ms)
    end

    assign(socket,
      messages: messages,
      tool_calls: tool_calls,
      token_stats: token_stats,
      session_meta: session_meta,
      live_offset: live_offset,
      loading: false
    )
  end

  defp poll_new_messages(socket) do
    session_id = socket.assigns.session_id
    file_path = resolve_file_path(session_id)
    offset = socket.assigns.live_offset

    case file_path && ConversationReader.read_from_offset(file_path, offset) do
      {:ok, [], _new_offset} ->
        socket

      {:ok, new_msgs, new_offset} ->
        all_messages = socket.assigns.messages ++ new_msgs
        # Keep last 200 messages in memory
        trimmed = Enum.take(all_messages, -200)
        token_stats = aggregate_token_stats(trimmed)
        tool_calls = extract_tool_calls(trimmed)

        assign(socket,
          messages: trimmed,
          tool_calls: tool_calls,
          token_stats: token_stats,
          live_offset: new_offset
        )

      _ ->
        socket
    end
  end

  # ---------------------------------------------------------------------------
  # Private: JSONL path resolution
  # ---------------------------------------------------------------------------

  @spec resolve_file_path(String.t()) :: String.t() | nil
  defp resolve_file_path(session_id) do
    conversations = ConversationWatcher.get_conversations()
    conv = Enum.find(conversations, fn c -> to_string(c.session_id) == session_id end)

    if conv do
      find_jsonl_file(conv.file)
    else
      # Fallback: scan projects directory directly
      scan_for_session(session_id)
    end
  end

  defp find_jsonl_file(filename) when is_binary(filename) do
    projects_dir = Path.expand("~/.claude/projects")

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

  defp find_jsonl_file(_), do: nil

  defp scan_for_session(session_id) do
    projects_dir = Path.expand("~/.claude/projects")

    case File.ls(projects_dir) do
      {:ok, dirs} ->
        Enum.find_value(dirs, fn dir ->
          dir_path = Path.join(projects_dir, dir)

          case File.ls(dir_path) do
            {:ok, files} ->
              Enum.find_value(files, fn f ->
                if String.ends_with?(f, ".jsonl") and String.contains?(f, session_id) do
                  Path.join(dir_path, f)
                end
              end)

            _ ->
              nil
          end
        end)

      _ ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Private: data aggregation
  # ---------------------------------------------------------------------------

  defp aggregate_token_stats(messages) do
    Enum.reduce(messages, empty_token_stats(), fn msg, acc ->
      case msg.usage do
        nil ->
          acc

        usage ->
          %{
            input: acc.input + (usage[:input_tokens] || usage.input_tokens || 0),
            output: acc.output + (usage[:output_tokens] || usage.output_tokens || 0),
            cache_read: acc.cache_read + (usage[:cache_read] || 0),
            cache_creation: acc.cache_creation + (usage[:cache_creation] || 0)
          }
      end
    end)
  end

  defp empty_token_stats do
    %{input: 0, output: 0, cache_read: 0, cache_creation: 0}
  end

  defp extract_tool_calls(messages) do
    messages
    |> Enum.flat_map(fn msg ->
      Enum.map(msg.tool_calls, fn tc ->
        Map.put(tc, :timestamp, msg.timestamp)
      end)
    end)
  end

  defp build_session_meta(session_id, messages) do
    first = List.first(messages)
    last = List.last(messages)

    conversations = ConversationWatcher.get_conversations()
    conv = Enum.find(conversations, fn c -> to_string(c.session_id) == session_id end)

    %{
      session_id: session_id,
      started_at: first && first.timestamp,
      last_message_at: last && last.timestamp,
      active: conv && conv.active,
      project: conv && conv.project
    }
  end

  defp token_total(%{input: i, output: o, cache_read: cr, cache_creation: cc}),
    do: i + o + cr + cc

  # ---------------------------------------------------------------------------
  # Private: formatting helpers
  # ---------------------------------------------------------------------------

  defp format_tokens(n) when is_integer(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000.0, 1)}M"
  end

  defp format_tokens(n) when is_integer(n) and n >= 1_000 do
    "#{Float.round(n / 1_000.0, 1)}k"
  end

  defp format_tokens(n) when is_integer(n), do: "#{n}"
  defp format_tokens(_), do: "0"

  defp format_ts(nil), do: ""

  defp format_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> String.slice(ts, 11, 8)
    end
  end

  defp format_ts(_), do: ""

  defp format_usage_inline(nil), do: ""

  defp format_usage_inline(usage) do
    i = usage[:input_tokens] || usage.input_tokens || 0
    o = usage[:output_tokens] || usage.output_tokens || 0
    "#{i}in / #{o}out"
  end

  defp session_project_name(nil), do: "Session"
  defp session_project_name(%{project: p}) when is_binary(p) and p != "", do: p
  defp session_project_name(_), do: "Session"

  defp session_active?(nil), do: false
  defp session_active?(%{active: true}), do: true
  defp session_active?(_), do: false

  defp session_status_label(nil), do: "unknown"
  defp session_status_label(%{active: true}), do: "active"
  defp session_status_label(_), do: "idle"

  defp status_tone(nil), do: "neutral"
  defp status_tone(%{active: true}), do: "success"
  defp status_tone(_), do: "neutral"

  defp session_duration(nil), do: ""

  defp session_duration(%{started_at: nil}), do: ""

  defp session_duration(%{started_at: start_ts, last_message_at: end_ts}) do
    with {:ok, start_dt, _} <- DateTime.from_iso8601(to_string(start_ts)),
         {:ok, end_dt, _} <- DateTime.from_iso8601(to_string(end_ts || start_ts)) do
      secs = DateTime.diff(end_dt, start_dt, :second)
      format_duration(secs)
    else
      _ -> ""
    end
  end

  defp session_duration(_), do: ""

  defp format_duration(secs) when secs < 60, do: "#{secs}s"
  defp format_duration(secs) when secs < 3600, do: "#{div(secs, 60)}m #{rem(secs, 60)}s"

  defp format_duration(secs) do
    h = div(secs, 3600)
    m = div(rem(secs, 3600), 60)
    "#{h}h #{m}m"
  end

  defp role_label("user"), do: "user"
  defp role_label("assistant"), do: "assistant"
  defp role_label("system"), do: "system"
  defp role_label(other), do: other

  defp role_tone("user"), do: "iris"
  defp role_tone("assistant"), do: "success"
  defp role_tone("system"), do: "warning"
  defp role_tone(_), do: "neutral"

  defp tc_status_tone(%{type: "tool_result", is_error: true}), do: "error"
  defp tc_status_tone(%{type: "tool_result"}), do: "success"
  defp tc_status_tone(_), do: "info"

  defp tc_status_label(%{type: "tool_result", is_error: true}), do: "error"
  defp tc_status_label(%{type: "tool_result"}), do: "success"
  defp tc_status_label(_), do: "call"

  defp tc_tokens(_tc), do: "—"

  defp tab_summary_label(%{tab: "Transcript", messages: msgs}) do
    "#{length(msgs)} messages"
  end

  defp tab_summary_label(%{tab: "Tool Calls", tool_calls: tcs}) do
    "#{length(tcs)} calls"
  end

  defp tab_summary_label(%{tab: "Tokens", token_stats: stats}) do
    total = token_total(stats)
    "#{format_tokens(total)} total"
  end

  defp tab_summary_label(_), do: ""

  defp message_row_style("user") do
    "padding: 10px 12px; border-radius: 8px; " <>
      "background: color-mix(in srgb, var(--ccem-iris, #7c6cf8) 8%, transparent); " <>
      "border-left: 3px solid var(--ccem-iris, #7c6cf8);"
  end

  defp message_row_style("assistant") do
    "padding: 10px 12px; border-radius: 8px; " <>
      "background: color-mix(in srgb, var(--ccem-ok, #22c55e) 6%, transparent); " <>
      "border-left: 3px solid var(--ccem-ok, #22c55e);"
  end

  defp message_row_style("system") do
    "padding: 10px 12px; border-radius: 8px; " <>
      "background: color-mix(in srgb, var(--ccem-warn, #f59e0b) 6%, transparent); " <>
      "border-left: 3px solid var(--ccem-warn, #f59e0b);"
  end

  defp message_row_style(_) do
    "padding: 10px 12px; border-radius: 8px; " <>
      "background: var(--ccem-bg-1); " <>
      "border-left: 3px solid var(--ccem-line);"
  end

  defp tool_chip_style do
    "height: 22px; padding: 0 8px; " <>
      "background: color-mix(in srgb, var(--ccem-iris, #7c6cf8) 12%, transparent); " <>
      "border: 1px solid color-mix(in srgb, var(--ccem-iris, #7c6cf8) 30%, transparent); " <>
      "border-radius: 11px; " <>
      "font-family: var(--ccem-font-mono, monospace); font-size: 11px; " <>
      "color: var(--ccem-iris, #7c6cf8); cursor: pointer;"
  end

  defp inspector_btn_style(true) do
    "height: 28px; padding: 0 10px; " <>
      "background: color-mix(in srgb, var(--ccem-accent) 18%, transparent); " <>
      "border: 1px solid color-mix(in srgb, var(--ccem-accent) 30%, transparent); " <>
      "border-radius: 5px; font-size: 12px; color: var(--ccem-accent); cursor: pointer;"
  end

  defp inspector_btn_style(false) do
    "height: 28px; padding: 0 10px; background: var(--ccem-bg-2); " <>
      "border: 1px solid var(--ccem-line); border-radius: 5px; " <>
      "font-size: 12px; color: var(--ccem-fg); cursor: pointer;"
  end
end
