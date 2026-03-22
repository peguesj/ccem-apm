defmodule ApmV5Web.RoutingLive do
  @moduledoc """
  Live routing graph LiveView for AgentLock authorization visualization.

  Displays an interactive D3.js force-directed graph showing authorization
  flow: sessions → formations → agents → tools, with risk level badges,
  approval gate diamonds, and audit trail side panels.
  """

  use ApmV5Web, :live_view

  alias ApmV5.Auth.{AuthorizationGate, SessionStore, ContextTracker}
  alias ApmV5.AgentRegistry

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "agentlock:authorization")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "agentlock:trust")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:agents")
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    socket =
      socket
      |> assign(page_title: "Routing Graph")
      |> assign(selected_agent: nil)
      |> assign(audit_trail: [])
      |> push_routing_data()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, push_routing_data(socket)}
  end

  @impl true
  def handle_info({:auth_granted, _}, socket), do: {:noreply, push_routing_data(socket)}
  def handle_info({:auth_denied, _}, socket), do: {:noreply, push_routing_data(socket)}
  def handle_info({:trust_ceiling_changed, _, _}, socket), do: {:noreply, push_routing_data(socket)}
  def handle_info({:agent_registered, _}, socket), do: {:noreply, push_routing_data(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_agent", %{"id" => agent_id}, socket) do
    audit =
      try do
        ApmV5.AuditLog.tail(20)
        |> Enum.filter(fn e ->
          String.starts_with?(Map.get(e, :event_type, ""), "auth:") and
            Map.get(e, :details, %{}) |> Map.get(:agent_id) == agent_id
        end)
      rescue
        _ -> []
      end

    {:noreply,
     socket
     |> assign(selected_agent: agent_id, audit_trail: audit)
     |> push_event("routing:audit_trail", %{agent_id: agent_id, entries: audit})}
  end

  @impl true
  def handle_event("approve_gate", %{"gate_id" => gate_id}, socket) do
    try do
      ApmV5.AgUi.ApprovalGate.approve(gate_id)
    rescue
      _ -> :ok
    end

    {:noreply, push_routing_data(socket)}
  end

  @impl true
  def handle_event("reject_gate", %{"gate_id" => gate_id}, socket) do
    try do
      ApmV5.AgUi.ApprovalGate.reject(gate_id, "Rejected via routing graph")
    rescue
      _ -> :ok
    end

    {:noreply, push_routing_data(socket)}
  end

  @impl true
  def handle_event("control_agent", %{"id" => _id, "action" => _action}, socket) do
    # Agent control delegated via API
    :ok

    {:noreply, push_routing_data(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <.sidebar_nav current_path="/routing" />

      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Authorization Routing Graph</h2>
          </div>
          <div class="flex items-center gap-2">
            <span class="badge badge-success badge-sm gap-1">
              <span class="w-2 h-2 rounded-full bg-success"></span> Authorized
            </span>
            <span class="badge badge-error badge-sm gap-1">
              <span class="w-2 h-2 rounded-full bg-error"></span> Denied
            </span>
            <span class="badge badge-warning badge-sm gap-1">
              <span class="w-2 h-2 rounded-full bg-warning"></span> Pending
            </span>
          </div>
        </header>

        <main class="flex-1 overflow-y-auto p-4">
        <div class="flex gap-4 h-full">
          <!-- Graph Canvas -->
          <div class="flex-1 bg-base-200 rounded-lg" style="min-height: 600px;">
            <div id="routing-graph" phx-hook="RoutingGraph" phx-update="ignore" class="w-full h-full" style="min-height: 600px;"></div>
          </div>

          <!-- Audit Side Panel -->
          <%= if @selected_agent do %>
            <div class="w-80 bg-base-200 rounded-lg p-4">
              <div class="flex justify-between items-center mb-4">
                <h3 class="font-bold text-sm">Audit Trail</h3>
                <button class="btn btn-ghost btn-xs" phx-click="select_agent" phx-value-id="">Close</button>
              </div>
              <p class="text-xs text-base-content/60 mb-4 font-mono"><%= @selected_agent %></p>
              <div class="space-y-2">
                <%= for entry <- @audit_trail do %>
                  <div class="card card-compact bg-base-300">
                    <div class="card-body py-2">
                      <span class="text-xs font-mono"><%= Map.get(entry, :event_type, "") %></span>
                      <span class="text-xs text-base-content/60"><%= Map.get(entry, :timestamp, "") %></span>
                    </div>
                  </div>
                <% end %>
                <%= if @audit_trail == [] do %>
                  <p class="text-xs text-base-content/40 text-center">No audit entries</p>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
        </main>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp push_routing_data(socket) do
    graph = build_routing_graph()
    summary = try do AuthorizationGate.summary() rescue _ -> %{} end
    trust_ceilings = try do ContextTracker.all_trust_ceilings() rescue _ -> %{} end

    push_event(socket, "routing:data", %{
      graph: graph,
      summary: summary,
      trust_ceilings: trust_ceilings
    })
  end

  defp build_routing_graph do
    agents =
      try do
        AgentRegistry.list_agents()
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    sessions = try do SessionStore.list_active() rescue _ -> [] end
    tools = try do AuthorizationGate.list_tools() rescue _ -> [] end

    pending_gates =
      try do
        ApmV5.AgUi.ApprovalGate.list_pending()
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    %{
      agents: Enum.map(agents, &agent_to_node/1),
      sessions: Enum.map(sessions, &session_to_node/1),
      tools: Enum.map(tools, &tool_to_node/1),
      gates: Enum.map(pending_gates, &gate_to_node/1)
    }
  end

  defp agent_to_node(agent) do
    %{
      id: Map.get(agent, :agent_id, ""),
      type: "agent",
      status: Map.get(agent, :status, "unknown"),
      role: Map.get(agent, :role, "agent"),
      formation_id: Map.get(agent, :formation_id),
      parent_id: Map.get(agent, :parent_agent_id)
    }
  end

  defp session_to_node(session) do
    %{
      id: session.id,
      type: "session",
      user_id: session.user_id,
      role: session.role,
      trust_ceiling: session.trust_ceiling,
      tool_calls: session.tool_call_count,
      denied: session.denied_count
    }
  end

  defp tool_to_node(tool) do
    %{
      id: tool.name,
      type: "tool",
      risk_level: tool.risk_level,
      requires_auth: tool.requires_auth
    }
  end

  defp gate_to_node(gate) do
    %{
      id: Map.get(gate, :gate_id, ""),
      type: "approval_gate",
      agent_id: Map.get(gate, :agent_id, ""),
      status: "pending",
      tool_name: get_in(gate, [:params, :tool_name]) || ""
    }
  end
end
