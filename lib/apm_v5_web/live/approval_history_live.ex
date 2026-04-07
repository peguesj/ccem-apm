defmodule ApmV5Web.ApprovalHistoryLive do
  @moduledoc """
  Approval history dashboard showing a filterable audit log of all
  authorization decisions (approve/deny) with full context.

  Part of US-326 — ApprovalAuditLog GenServer and APM dashboard audit view.
  """

  use ApmV5Web, :live_view

  alias ApmV5.Auth.ApprovalAuditLog

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "agentlock:audit")
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    {:ok,
     socket
     |> assign(:page_title, "Approval History")
     |> assign(:filter_agent_id, "")
     |> assign(:filter_tool_name, "")
     |> assign(:filter_decision, "all")
     |> assign(:entries, load_entries([]))}
  end

  @impl true
  def handle_event("filter", params, socket) do
    agent_id = Map.get(params, "agent_id", "")
    tool_name = Map.get(params, "tool_name", "")
    decision = Map.get(params, "decision", "all")

    opts = build_filter_opts(agent_id, tool_name, decision)

    {:noreply,
     socket
     |> assign(:filter_agent_id, agent_id)
     |> assign(:filter_tool_name, tool_name)
     |> assign(:filter_decision, decision)
     |> assign(:entries, load_entries(opts))}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    opts = build_filter_opts(socket.assigns.filter_agent_id, socket.assigns.filter_tool_name, socket.assigns.filter_decision)
    {:noreply, assign(socket, :entries, load_entries(opts))}
  end

  @impl true
  def handle_info({:audit_entry_added, _entry}, socket) do
    opts = build_filter_opts(socket.assigns.filter_agent_id, socket.assigns.filter_tool_name, socket.assigns.filter_decision)
    {:noreply, assign(socket, :entries, load_entries(opts))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-[#0f1420] text-gray-200 p-6">
      <div class="max-w-7xl mx-auto">
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-2xl font-bold text-white">Approval History</h1>
          <span class="text-sm text-gray-400"><%= length(@entries) %> entries</span>
        </div>

        <!-- Filters -->
        <form phx-change="filter" class="flex gap-4 mb-6">
          <input
            type="text"
            name="agent_id"
            value={@filter_agent_id}
            placeholder="Filter by agent ID..."
            class="bg-[#1c2536] border border-gray-700 rounded px-3 py-2 text-sm text-gray-200 placeholder-gray-500 focus:border-blue-500 focus:outline-none"
          />
          <input
            type="text"
            name="tool_name"
            value={@filter_tool_name}
            placeholder="Filter by tool name..."
            class="bg-[#1c2536] border border-gray-700 rounded px-3 py-2 text-sm text-gray-200 placeholder-gray-500 focus:border-blue-500 focus:outline-none"
          />
          <select
            name="decision"
            class="bg-[#1c2536] border border-gray-700 rounded px-3 py-2 text-sm text-gray-200 focus:border-blue-500 focus:outline-none"
          >
            <option value="all" selected={@filter_decision == "all"}>All decisions</option>
            <option value="approve" selected={@filter_decision == "approve"}>Approved</option>
            <option value="deny" selected={@filter_decision == "deny"}>Denied</option>
          </select>
        </form>

        <!-- Table -->
        <div class="bg-[#1c2536] rounded-lg border border-gray-700 overflow-hidden">
          <table class="w-full text-sm">
            <thead class="bg-[#151b28] text-gray-400 text-xs uppercase tracking-wider">
              <tr>
                <th class="px-4 py-3 text-left">Timestamp</th>
                <th class="px-4 py-3 text-left">Agent</th>
                <th class="px-4 py-3 text-left">Tool</th>
                <th class="px-4 py-3 text-left">Decision</th>
                <th class="px-4 py-3 text-left">Risk</th>
                <th class="px-4 py-3 text-left">Context</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-700/50">
              <%= for entry <- @entries do %>
                <tr class="hover:bg-[#1a2233] transition-colors">
                  <td class="px-4 py-3 text-gray-400 font-mono text-xs whitespace-nowrap">
                    <%= format_timestamp(entry.timestamp) %>
                  </td>
                  <td class="px-4 py-3 text-gray-200 font-mono text-xs">
                    <%= truncate(to_string(entry.agent_id), 24) %>
                  </td>
                  <td class="px-4 py-3 text-blue-400 font-mono text-xs">
                    <%= entry.tool_name %>
                  </td>
                  <td class="px-4 py-3">
                    <span class={decision_badge_class(entry.decision)}>
                      <%= entry.decision %>
                    </span>
                  </td>
                  <td class="px-4 py-3">
                    <span class={risk_badge_class(entry[:risk_level])}>
                      <%= entry[:risk_level] || "—" %>
                    </span>
                  </td>
                  <td class="px-4 py-3 text-gray-500 text-xs max-w-xs truncate">
                    <%= format_context(entry[:context_snapshot]) %>
                  </td>
                </tr>
              <% end %>
              <%= if @entries == [] do %>
                <tr>
                  <td colspan="6" class="px-4 py-8 text-center text-gray-500">
                    No approval history entries found.
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp load_entries(opts) do
    ApprovalAuditLog.list_entries(opts)
  end

  defp build_filter_opts(agent_id, tool_name, decision) do
    []
    |> then(fn opts -> if agent_id != "", do: Keyword.put(opts, :agent_id, agent_id), else: opts end)
    |> then(fn opts -> if tool_name != "", do: Keyword.put(opts, :tool_name, tool_name), else: opts end)
    |> then(fn opts ->
      case decision do
        "approve" -> Keyword.put(opts, :decision, :approve)
        "deny" -> Keyword.put(opts, :decision, :deny)
        _ -> opts
      end
    end)
  end

  defp format_timestamp(nil), do: "—"
  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp truncate(str, max) when byte_size(str) > max, do: String.slice(str, 0, max) <> "..."
  defp truncate(str, _max), do: str

  defp decision_badge_class(:approve), do: "px-2 py-0.5 rounded text-xs font-medium bg-green-900/50 text-green-400 border border-green-700/50"
  defp decision_badge_class(:deny), do: "px-2 py-0.5 rounded text-xs font-medium bg-red-900/50 text-red-400 border border-red-700/50"
  defp decision_badge_class(_), do: "px-2 py-0.5 rounded text-xs font-medium bg-gray-700/50 text-gray-400"

  defp risk_badge_class(:critical), do: "text-xs text-red-400 font-medium"
  defp risk_badge_class(:high), do: "text-xs text-orange-400 font-medium"
  defp risk_badge_class(:medium), do: "text-xs text-yellow-400 font-medium"
  defp risk_badge_class(:low), do: "text-xs text-green-400 font-medium"
  defp risk_badge_class(_), do: "text-xs text-gray-500"

  defp format_context(nil), do: "—"
  defp format_context(ctx) when map_size(ctx) == 0, do: "—"
  defp format_context(ctx) do
    parts = []
    parts = if ctx[:action_type], do: parts ++ ["#{ctx.action_type}"], else: parts
    parts = if ctx[:action_detail], do: parts ++ [ctx.action_detail], else: parts
    if parts == [], do: "—", else: Enum.join(parts, " — ")
  end
end
