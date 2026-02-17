defmodule ApmV4.A2ui.ComponentBuilder do
  @moduledoc """
  Builds declarative A2UI component specifications from APM state.

  Components follow the Google A2UI protocol: each is a JSON object
  with a unique `id`, `type`, and type-specific fields. Supported types:
  card, chart, table, alert, badge, progress.
  """

  alias ApmV4.AgentRegistry

  @doc """
  Build all dashboard components from current APM state.
  Returns a list of component maps.
  """
  @spec build_all() :: [map()]
  def build_all do
    agents = AgentRegistry.list_agents()
    notifications = AgentRegistry.get_notifications()
    sessions = AgentRegistry.list_sessions()

    []
    |> Kernel.++(build_stat_cards(agents, sessions, notifications))
    |> Kernel.++(build_agent_table(agents))
    |> Kernel.++(build_status_chart(agents))
    |> Kernel.++(build_notification_alerts(notifications))
    |> Kernel.++(build_agent_badges(agents))
    |> Kernel.++(build_tier_progress(agents))
  end

  @doc "Build stat cards for agent counts and summaries."
  @spec build_stat_cards([map()], [map()], [map()]) :: [map()]
  def build_stat_cards(agents, sessions, notifications) do
    active = Enum.count(agents, &(&1.status == "active"))
    idle = Enum.count(agents, &(&1.status == "idle"))
    errors = Enum.count(agents, &(&1.status == "error"))

    [
      %{
        id: "card-agent-count",
        type: "card",
        title: "Total Agents",
        body: to_string(length(agents)),
        footer: "#{active} active, #{idle} idle, #{errors} errors",
        variant: "primary"
      },
      %{
        id: "card-session-count",
        type: "card",
        title: "Sessions",
        body: to_string(length(sessions)),
        footer: "Active monitoring sessions",
        variant: "info"
      },
      %{
        id: "card-notification-count",
        type: "card",
        title: "Notifications",
        body: to_string(length(notifications)),
        footer: "Pending notifications",
        variant: "warning"
      },
      %{
        id: "card-error-count",
        type: "card",
        title: "Errors",
        body: to_string(errors),
        footer: "Agents in error state",
        variant: if(errors > 0, do: "error", else: "success")
      }
    ]
  end

  @doc "Build the agents table component."
  @spec build_agent_table([map()]) :: [map()]
  def build_agent_table(agents) do
    rows =
      Enum.map(agents, fn agent ->
        %{
          id: agent.id,
          name: agent.name,
          tier: agent.tier,
          status: agent.status,
          last_seen: agent.last_seen
        }
      end)

    [
      %{
        id: "table-agents",
        type: "table",
        columns: ["id", "name", "tier", "status", "last_seen"],
        rows: rows,
        sortable: true
      }
    ]
  end

  @doc "Build a status distribution chart."
  @spec build_status_chart([map()]) :: [map()]
  def build_status_chart(agents) do
    counts =
      agents
      |> Enum.group_by(& &1.status)
      |> Enum.map(fn {status, group} -> {status, length(group)} end)
      |> Enum.into(%{})

    labels = Map.keys(counts)
    data = Map.values(counts)

    [
      %{
        id: "chart-status-distribution",
        type: "chart",
        chart_type: "pie",
        labels: labels,
        data: data
      }
    ]
  end

  @doc "Build alert components from recent notifications."
  @spec build_notification_alerts([map()]) :: [map()]
  def build_notification_alerts(notifications) do
    notifications
    |> Enum.take(10)
    |> Enum.map(fn notif ->
      %{
        id: "alert-notif-#{notif.id}",
        type: "alert",
        level: notif.level,
        message: "#{notif.title}: #{notif.message}",
        dismissible: true
      }
    end)
  end

  @doc "Build badge components for each agent's status."
  @spec build_agent_badges([map()]) :: [map()]
  def build_agent_badges(agents) do
    Enum.map(agents, fn agent ->
      %{
        id: "badge-agent-#{agent.id}",
        type: "badge",
        label: agent.name,
        value: agent.status,
        variant: status_variant(agent.status)
      }
    end)
  end

  @doc "Build progress components for tier distribution."
  @spec build_tier_progress([map()]) :: [map()]
  def build_tier_progress(agents) do
    total = max(length(agents), 1)

    agents
    |> Enum.group_by(& &1.tier)
    |> Enum.sort_by(fn {tier, _} -> tier end)
    |> Enum.map(fn {tier, group} ->
      %{
        id: "progress-tier-#{tier}",
        type: "progress",
        label: "Tier #{tier}",
        value: length(group),
        max: total,
        percentage: Float.round(length(group) / total * 100, 1)
      }
    end)
  end

  defp status_variant("active"), do: "success"
  defp status_variant("idle"), do: "ghost"
  defp status_variant("error"), do: "error"
  defp status_variant("discovered"), do: "info"
  defp status_variant(_), do: "default"
end
