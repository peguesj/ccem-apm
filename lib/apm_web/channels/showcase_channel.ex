defmodule ApmWeb.ShowcaseChannel do
  @moduledoc """
  Phoenix Channel for real-time showcase sync.

  Accepts WebSocket connections from the showcase client and streams:
  - Formation events: agent spawns, wave completions, heartbeats
  - Agent context updates: what agents are doing right now
  - D3 graph diffs: incremental node/edge updates
  - APM notifications: project-scoped alerts

  Topic: "showcase:{project}" (e.g. "showcase:ccem") or "showcase:all"

  Clients connect via:
    socket.channel("showcase:ccem", {})
    socket.channel("showcase:all", {})

  Push events to client:
    "formation:update" — %{formation_id, agents, wave, status}
    "agent:context"    — %{agent_id, label, event_type, tool}
    "graph:diff"       — %{added: [], removed: [], updated: []}
    "notification"     — %{title, message, type, category}
    "apm:heartbeat"    — %{ts, active_agents, active_formations}
  """

  use Phoenix.Channel

  require Logger

  alias Apm.AgentRegistry
  alias Apm.AgUi.{ActivityTracker, AgentContextStore}

  @heartbeat_interval_ms 5_000

  @impl true
  def join("showcase:" <> _project, _payload, socket) do
    Phoenix.PubSub.subscribe(Apm.PubSub, "apm:agents")
    Phoenix.PubSub.subscribe(Apm.PubSub, "apm:notifications")
    Phoenix.PubSub.subscribe(Apm.PubSub, "apm:agent_context")
    Phoenix.PubSub.subscribe(Apm.PubSub, "apm:formations")
    Phoenix.PubSub.subscribe(Apm.PubSub, "upm:decisions")

    schedule_heartbeat()

    # Send initial snapshot so the client bootstraps without polling
    agents = AgentRegistry.list_agents()
    contexts = AgentContextStore.list_contexts()

    {:ok,
     %{
       status: "connected",
       snapshot: %{
         agents: Enum.map(agents, &agent_summary/1),
         contexts: contexts,
         active_count: Enum.count(agents, &(&1.status == "active"))
       }
     }, socket}
  end

  @impl true
  def handle_in("get_snapshot", _payload, socket) do
    agents = AgentRegistry.list_agents()
    contexts = AgentContextStore.list_contexts()

    push(socket, "snapshot", %{
      agents: Enum.map(agents, &agent_summary/1),
      contexts: contexts,
      ts: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    {:reply, :ok, socket}
  end

  def handle_in("get_agent_context", %{"agent_id" => agent_id}, socket) do
    context = AgentContextStore.get_context(agent_id)
    recent = AgentContextStore.recent_events(agent_id, 10)
    activity = try_get_activity(agent_id)

    {:reply,
     {:ok,
      %{
        agent_id: agent_id,
        context: context,
        recent_events: recent,
        activity: activity
      }}, socket}
  end

  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "unknown"}}, socket}
  end

  # -- PubSub Handlers --------------------------------------------------------

  @impl true
  def handle_info({:agent_registered, agent}, socket) do
    push(socket, "agent:update", %{
      action: "registered",
      agent: agent_summary(agent),
      context: AgentContextStore.get_context(agent.id)
    })

    push(socket, "graph:diff", %{
      added: [graph_node(agent)],
      removed: [],
      updated: []
    })

    {:noreply, socket}
  end

  def handle_info({:agent_updated, agent}, socket) do
    push(socket, "agent:update", %{
      action: "updated",
      agent: agent_summary(agent),
      context: AgentContextStore.get_context(agent.id)
    })

    push(socket, "graph:diff", %{
      added: [],
      removed: [],
      updated: [graph_node(agent)]
    })

    {:noreply, socket}
  end

  def handle_info({:agent_context_updated, agent_id, context}, socket) do
    push(socket, "agent:context", %{
      agent_id: agent_id,
      label: context.activity_label,
      event_type: context.current_event_type,
      tool: context.current_tool,
      recent: Enum.take(context.recent_events, 5),
      updated_at: context.updated_at
    })

    {:noreply, socket}
  end

  def handle_info({:notification_added, notif}, socket) do
    push(socket, "notification", %{
      title: notif.title,
      message: notif.message,
      type: notif.type,
      category: notif.category,
      formation_id: notif.formation_id,
      agent_id: notif.agent_id,
      ts: notif.timestamp
    })

    {:noreply, socket}
  end

  def handle_info({:gate_created, gate}, socket) do
    push(socket, "upm:decision_gate", %{
      gate_id: gate.gate_id,
      question: gate.question,
      context: gate.context,
      options: gate.options,
      status: "pending",
      requested_at: gate.requested_at
    })

    {:noreply, socket}
  end

  def handle_info({:gate_resolved, gate}, socket) do
    push(socket, "upm:decision_resolved", %{
      gate_id: gate.gate_id,
      decision: gate.decision,
      method: gate.method,
      resolved_at: gate.resolved_at
    })

    {:noreply, socket}
  end

  def handle_info(:heartbeat, socket) do
    agents = AgentRegistry.list_agents()
    active = Enum.count(agents, &(&1.status == "active"))

    push(socket, "apm:heartbeat", %{
      ts: DateTime.utc_now() |> DateTime.to_iso8601(),
      active_agents: active,
      total_agents: length(agents)
    })

    schedule_heartbeat()
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- Private ----------------------------------------------------------------

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
  end

  defp agent_summary(agent) do
    %{
      id: agent.id,
      name: agent.name,
      status: agent.status,
      tier: agent.tier,
      agent_type: agent[:agent_type] || "individual",
      formation_id: agent[:formation_id],
      role: agent[:role],
      wave: agent[:wave],
      namespace: agent[:namespace],
      last_seen: agent.last_seen
    }
  end

  defp graph_node(agent) do
    %{
      id: agent.id,
      label: agent.name,
      status: agent.status,
      type: agent[:agent_type] || "individual",
      formation_id: agent[:formation_id],
      parent_id: agent[:parent_id],
      wave: agent[:wave],
      tier: agent.tier
    }
  end

  defp try_get_activity(agent_id) do
    if Process.whereis(ActivityTracker) do
      ActivityTracker.get_activity(agent_id)
    else
      nil
    end
  end
end
