defmodule ApmV5Web.Components.AgentPanel do
  @moduledoc """
  Agent Fleet panel component for DashboardLive.

  Extracted from DashboardLive (US-R13) as a reusable Phoenix functional component.
  Renders the Agent Fleet grid with column headers, per-agent rows, status badges,
  tier badges, and a phx-click handler that delegates back to the parent LiveView
  via the select_agent event.

  Requires the parent LiveView to handle the `select_agent` event.
  """

  use Phoenix.Component

  attr :agents, :list, required: true, doc: "Full agent list from AgentRegistry"
  attr :filter_status, :string, default: nil, doc: "Optional status filter"
  attr :filter_namespace, :string, default: nil, doc: "Optional namespace filter"
  attr :filter_agent_type, :string, default: nil, doc: "Optional agent type filter"
  attr :filter_query, :string, default: nil, doc: "Optional free-text query filter"

  @doc "Renders the Agent Fleet card grid panel."
  def agent_fleet(assigns) do
    ~H"""
    <div>
      <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-2">
        Agent Fleet
      </h3>
      <%!-- Column headers --%>
      <div class="grid grid-cols-[24px_1fr_80px_60px_80px] gap-2 px-3 mb-1 text-[10px] uppercase tracking-wider text-base-content/30">
        <span></span>
        <span>Agent</span>
        <span class="text-right">Last Seen</span>
        <span class="text-center">Type</span>
        <span class="text-center">Status</span>
      </div>
      <%!-- Agent rows --%>
      <div class="space-y-1">
        <div
          :for={agent <- filtered_agents(assigns)}
          class="card bg-base-200 border border-base-300 hover:border-primary/50 transition-colors cursor-pointer"
          phx-click="select_agent"
          phx-value-agent_id={agent.id}
        >
          <div class="grid grid-cols-[24px_1fr_80px_60px_80px] gap-2 items-center px-3 py-2">
            <div class={["badge badge-xs", tier_badge_class(agent.tier)]}>
              {agent.tier}
            </div>
            <div>
              <div class="text-sm font-medium truncate flex items-center gap-1.5">
                {agent.name}
                <span :if={agent[:member_count] && agent[:member_count] > 1} class="badge badge-xs badge-info">
                  {agent[:member_count]}
                </span>
                <span :if={agent[:story_id]} class="badge badge-xs badge-primary badge-outline font-mono">
                  {agent[:story_id]}
                </span>
              </div>
              <div class="text-[10px] text-base-content/30 flex items-center gap-1">
                <span class="font-mono">{agent.id}</span>
                <span :if={agent[:namespace]} class="text-primary/60">/ {agent[:namespace]}</span>
              </div>
            </div>
            <div class="text-right text-xs text-base-content/40">
              {format_last_seen(agent.last_seen)}
            </div>
            <div class="text-center">
              <span class={["badge badge-xs", agent_type_badge_class(agent[:agent_type])]}>
                {agent[:agent_type] || "individual"}
              </span>
            </div>
            <div class="text-center">
              <span class={["badge badge-sm", status_badge_class(agent.status)]}>
                {agent.status}
              </span>
            </div>
          </div>
        </div>
        <div :if={@agents == []} class="text-center text-base-content/30 py-8 text-sm">
          No agents registered. POST to /api/register to add agents.
        </div>
      </div>
    </div>
    """
  end

  # ============================
  # Private Helpers
  # ============================

  @spec filtered_agents(map()) :: list()
  defp filtered_agents(assigns) do
    assigns.agents
    |> filter_by_status(assigns[:filter_status])
    |> filter_by_namespace(assigns[:filter_namespace])
    |> filter_by_agent_type(assigns[:filter_agent_type])
    |> filter_by_query(assigns[:filter_query])
  end

  @spec filter_by_status(list(), String.t() | nil) :: list()
  defp filter_by_status(agents, nil), do: agents
  defp filter_by_status(agents, ""), do: agents

  defp filter_by_status(agents, status) do
    Enum.filter(agents, fn a ->
      (Map.get(a, :status) || Map.get(a, "status", "")) == status
    end)
  end

  @spec filter_by_namespace(list(), String.t() | nil) :: list()
  defp filter_by_namespace(agents, nil), do: agents
  defp filter_by_namespace(agents, ""), do: agents

  defp filter_by_namespace(agents, ns) do
    Enum.filter(agents, fn a ->
      (Map.get(a, :namespace) || Map.get(a, "namespace", "")) == ns
    end)
  end

  @spec filter_by_agent_type(list(), String.t() | nil) :: list()
  defp filter_by_agent_type(agents, nil), do: agents
  defp filter_by_agent_type(agents, ""), do: agents

  defp filter_by_agent_type(agents, type) do
    Enum.filter(agents, fn a ->
      (Map.get(a, :agent_type) || Map.get(a, "agent_type", "individual")) == type
    end)
  end

  @spec filter_by_query(list(), String.t() | nil) :: list()
  defp filter_by_query(agents, nil), do: agents
  defp filter_by_query(agents, ""), do: agents

  defp filter_by_query(agents, query) do
    q = String.downcase(query)

    Enum.filter(agents, fn a ->
      name = String.downcase(Map.get(a, :name) || Map.get(a, "name", "") || "")
      id = String.downcase(Map.get(a, :id) || Map.get(a, "id", "") || "")
      String.contains?(name, q) or String.contains?(id, q)
    end)
  end

  @spec format_last_seen(String.t() | nil | any()) :: String.t()
  defp format_last_seen(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)

        cond do
          diff < 60 -> "#{diff}s ago"
          diff < 3600 -> "#{div(diff, 60)}m ago"
          true -> "#{div(diff, 3600)}h ago"
        end

      _ ->
        "unknown"
    end
  end

  defp format_last_seen(_), do: "unknown"

  @spec status_badge_class(String.t()) :: String.t()
  defp status_badge_class("active"), do: "badge-success"
  defp status_badge_class("idle"), do: "badge-ghost"
  defp status_badge_class("error"), do: "badge-error"
  defp status_badge_class("discovered"), do: "badge-info"
  defp status_badge_class("completed"), do: "badge-accent"
  defp status_badge_class(_), do: "badge-ghost"

  @spec agent_type_badge_class(String.t() | nil) :: String.t()
  defp agent_type_badge_class("squadron"), do: "badge-info"
  defp agent_type_badge_class("swarm"), do: "badge-warning"
  defp agent_type_badge_class("orchestrator"), do: "badge-accent"
  defp agent_type_badge_class(_), do: "badge-ghost"

  @spec tier_badge_class(integer() | any()) :: String.t()
  defp tier_badge_class(1), do: "badge-primary"
  defp tier_badge_class(2), do: "badge-secondary"
  defp tier_badge_class(3), do: "badge-warning"
  defp tier_badge_class(_), do: "badge-ghost"
end
