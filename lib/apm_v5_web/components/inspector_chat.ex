defmodule ApmV5Web.Components.InspectorChat do
  @moduledoc """
  InspectorChatLive — contextual AG-UI chat panel for the inspector column.

  Subscribes to AG-UI events PubSub for real-time TEXT_MESSAGE_* events,
  scoped to the selected resource. Input field sends messages via
  POST /api/v2/ag-ui/emit. Renders tool calls inline as collapsible cards.
  """

  use Phoenix.Component

  attr :scope, :string, default: "global"
  attr :messages, :list, default: []
  attr :chat_input, :string, default: ""
  attr :selected_agent, :any, default: nil

  def chat_panel(assigns) do
    ~H"""
    <div class="flex flex-col h-full" id="inspector-chat">
      <%!-- Scope breadcrumb --%>
      <div class="px-2 py-1 bg-base-300/50 text-xs flex items-center gap-1 border-b border-base-300">
        <span class="text-base-content/40">Scope:</span>
        <span class="text-primary font-mono">{@scope}</span>
      </div>

      <%!-- Messages area --%>
      <div class="flex-1 overflow-y-auto p-2 space-y-2 min-h-0" id="chat-messages" phx-update="stream">
        <div :if={@messages == []} class="text-center text-base-content/30 py-8 text-xs">
          No messages yet. Type below to start a conversation.
        </div>

        <div :for={msg <- @messages} class={[
          "rounded-lg p-2 text-xs max-w-[95%]",
          if(msg["role"] == "user", do: "ml-auto bg-primary/20 text-primary-content", else: "bg-base-300")
        ]}>
          <%!-- Message header --%>
          <div class="flex items-center gap-1 mb-1">
            <span class={[
              "badge badge-xs",
              if(msg["role"] == "user", do: "badge-primary", else: "badge-ghost")
            ]}>
              {msg["role"] || "system"}
            </span>
            <span :if={msg["agent_id"]} class="text-[10px] text-base-content/40 font-mono truncate max-w-[120px]">
              {msg["agent_id"]}
            </span>
            <span class="text-[10px] text-base-content/30 ml-auto">
              {format_timestamp(msg["timestamp"])}
            </span>
          </div>

          <%!-- Message content --%>
          <div :if={msg["type"] != "TOOL_CALL"} class="whitespace-pre-wrap break-words">
            {msg["content"]}
          </div>

          <%!-- Tool call card (collapsible) --%>
          <div :if={msg["type"] == "TOOL_CALL"} class="border border-base-content/10 rounded p-1.5 mt-1">
            <details>
              <summary class="cursor-pointer text-warning font-mono text-[11px]">
                Tool: {msg["tool_name"] || "unknown"}
              </summary>
              <pre class="text-[10px] mt-1 overflow-x-auto bg-base-100 rounded p-1 max-h-24">
                {msg["content"]}
              </pre>
            </details>
          </div>
        </div>
      </div>

      <%!-- Input area --%>
      <form phx-submit="chat:send" class="p-2 border-t border-base-300">
        <div class="flex gap-1">
          <input
            type="text"
            name="content"
            value={@chat_input}
            placeholder="Message..."
            class="input input-xs input-bordered flex-1 bg-base-100"
            autocomplete="off"
            phx-change="chat:input"
          />
          <button type="submit" class="btn btn-xs btn-primary">
            Send
          </button>
        </div>
      </form>
    </div>
    """
  end

  defp format_timestamp(nil), do: ""
  defp format_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> String.slice(ts, 11, 8)
    end
  end
  defp format_timestamp(_), do: ""
end
