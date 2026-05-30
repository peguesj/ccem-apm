defmodule ApmV5Web.FleetLive do
  @moduledoc """
  Observe — Fleet LiveView (CP-176 / US-451).

  Displays all registered agents in a grid or list layout with live filtering
  and an inspector panel for per-agent detail. Subscribes to `apm:agents`
  PubSub topic for real-time agent updates.

  ## Layout
  - Filter rail: search input + Grid/List segmented control + status filter badges
  - Grid view: flex-wrap of `<.agent_card>` components with sparkline activity
  - List view: `<.data_table>` with columns Agent, Role, Status, Tokens, Last Active
  - Inspector: selected agent detail in the right `<.inspector_panel>`
  """

  use ApmV5Web, :live_view

  alias ApmV5.AgentRegistry

  @refresh_ms 5_000
  @pubsub_topic "apm:agents"

  # Status options for the filter rail.
  @status_filters ["All", "active", "idle", "error", "done"]

  # ---------------------------------------------------------------------------
  # mount/3
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic)
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    agents = load_agents()

    {:ok,
     socket
     |> assign(
       page_title: "Fleet",
       agents: agents,
       filter: "",
       status_filter: "All",
       status_filters: @status_filters,
       view_mode: "Grid",
       sidebar_collapsed: false,
       inspector_open: false,
       inspector_mode: "selection",
       selected_agent: nil
     )
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  # ---------------------------------------------------------------------------
  # handle_info/2
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, agents: load_agents())}
  end

  def handle_info({:agent_registered, _agent}, socket) do
    {:noreply, assign(socket, agents: load_agents())}
  end

  def handle_info({:agent_updated, _agent}, socket) do
    {:noreply, assign(socket, agents: load_agents())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # handle_event/3
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("filter", %{"value" => value}, socket) do
    {:noreply, assign(socket, filter: value)}
  end

  @impl true
  def handle_event("set_view", %{"value" => mode}, socket) do
    {:noreply, assign(socket, view_mode: mode)}
  end

  @impl true
  def handle_event("set_status_filter", %{"status" => status}, socket) do
    {:noreply, assign(socket, status_filter: status)}
  end

  @impl true
  def handle_event("select_agent", %{"id" => agent_id}, socket) do
    agent = Enum.find(socket.assigns.agents, &(to_string(&1.id) == agent_id))

    {:noreply,
     assign(socket,
       selected_agent: agent,
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

  # ---------------------------------------------------------------------------
  # render/1
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :filtered_agents, filter_agents(assigns.agents, assigns.filter, assigns.status_filter))

    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav current_path="/fleet" />
      </:sidebar>

      <:topbar>
        <.top_bar project_name="CCEM APM" />
      </:topbar>

      <:main>
        <%!-- Page header --%>
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
          <div style="display: flex; align-items: baseline; gap: 10px;">
            <h1 style="margin: 0; font-size: 16px; font-weight: 600; color: var(--ccem-fg);">
              Fleet
            </h1>
            <span style="font-size: 12px; color: var(--ccem-fg-dim);">
              {@filtered_agents |> length()} of {@agents |> length()} agents
            </span>
          </div>
          <button
            phx-click="toggle_inspector"
            style="display: flex; align-items: center; justify-content: center; width: 28px; height: 28px; background: var(--ccem-bg-2); border: 1px solid var(--ccem-line); border-radius: 5px; cursor: pointer; color: var(--ccem-fg-dim); font-size: 13px;"
            title="Toggle inspector"
          >
            &#9776;
          </button>
        </div>

        <%!-- Stat tiles row --%>
        <div style="display: flex; gap: 12px; margin-bottom: 16px; flex-wrap: wrap;">
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Total" value={to_string(length(@agents))} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Active" value={to_string(count_by_status(@agents, "active"))} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Idle" value={to_string(count_by_status(@agents, "idle"))} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Error" value={to_string(count_by_status(@agents, "error"))} />
          </.card>
        </div>

        <%!-- Filter rail --%>
        <div style="display: flex; align-items: center; gap: 10px; margin-bottom: 16px; flex-wrap: wrap;">
          <%!-- Search input --%>
          <div style="flex: 1; min-width: 180px; max-width: 320px;">
            <.ds_input
              type="search"
              placeholder="Filter agents..."
              value={@filter}
              phx-change="filter"
              phx-debounce="200"
              name="value"
            />
          </div>

          <%!-- Grid/List toggle --%>
          <.segmented_control
            options={["Grid", "List"]}
            active={@view_mode}
            on_change="set_view"
          />

          <%!-- Status filter badges --%>
          <div style="display: flex; align-items: center; gap: 6px; flex-wrap: wrap;">
            <span style="font-size: 11px; color: var(--ccem-fg-dim); font-weight: 500;">Status:</span>
            <%= for status <- @status_filters do %>
              <button
                phx-click="set_status_filter"
                phx-value-status={status}
                style={
                  "padding: 2px 8px; font-size: 11px; font-weight: 500; border-radius: 999px; cursor: pointer; " <>
                    "border: 1px solid; transition: background 120ms, color 120ms; " <>
                    status_filter_style(@status_filter, status)
                }
              >
                {status}
              </button>
            <% end %>
          </div>
        </div>

        <%!-- Empty state --%>
        <%= if @filtered_agents == [] do %>
          <div style="display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 48px 16px; color: var(--ccem-fg-dim);">
            <svg xmlns="http://www.w3.org/2000/svg" width="40" height="40" fill="none" viewBox="0 0 24 24" stroke="currentColor" style="opacity: 0.3; margin-bottom: 12px;">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0z" />
            </svg>
            <p style="font-size: 14px; font-weight: 500; margin: 0 0 4px;">No agents found</p>
            <p style="font-size: 12px; margin: 0; opacity: 0.6;">
              <%= if @filter != "" or @status_filter != "All" do %>
                Try adjusting the filter or status selection.
              <% else %>
                Register agents via the /api/register endpoint or APM hooks.
              <% end %>
            </p>
          </div>

        <%!-- Grid view --%>
        <% else %>
          <%= if @view_mode == "Grid" do %>
            <div style="display: flex; flex-wrap: wrap; gap: 12px;">
              <%= for agent <- @filtered_agents do %>
                <div
                  phx-click="select_agent"
                  phx-value-id={to_string(agent.id)}
                  style={
                    "cursor: pointer; " <>
                      if(@selected_agent && to_string(@selected_agent.id) == to_string(agent.id),
                        do: "outline: 2px solid var(--ccem-accent); outline-offset: 2px; border-radius: 8px;",
                        else: ""
                      )
                  }
                >
                  <.agent_card
                    agent_id={to_string(agent.id)}
                    name={agent_name(agent)}
                    role={agent_role(agent)}
                    status={agent_status(agent)}
                  >
                    <:activity>
                      <.sparkline
                        data={agent.sparkline_data}
                        live_dot={agent_status(agent) == "active"}
                        width={160}
                        height={24}
                      />
                    </:activity>
                  </.agent_card>
                </div>
              <% end %>
            </div>

          <%!-- List view --%>
          <% else %>
            <.card padded={false}>
              <.data_table id="fleet-table" rows={@filtered_agents}>
                <:col :let={agent} label="Agent">
                  <div style="display: flex; align-items: center; gap: 8px;">
                    <svg
                      width="16"
                      height="16"
                      viewBox="0 0 5 5"
                      xmlns="http://www.w3.org/2000/svg"
                      style="border-radius: 3px; flex-shrink: 0; background: var(--ccem-bg-2);"
                    >
                      <%= for {row, col, on} <- identicon_cells(to_string(agent.id)) do %>
                        <%= if on do %>
                          <rect x={col} y={row} width="1" height="1" fill="var(--ccem-accent)" opacity="0.9" />
                        <% end %>
                      <% end %>
                    </svg>
                    <button
                      phx-click="select_agent"
                      phx-value-id={to_string(agent.id)}
                      style="background: none; border: none; padding: 0; font-size: 13px; font-weight: 500; color: var(--ccem-fg); cursor: pointer; text-align: left; font-family: var(--ccem-font-sans, inherit);"
                    >
                      {agent_name(agent)}
                    </button>
                  </div>
                </:col>
                <:col :let={agent} label="Role">
                  <span style="font-family: var(--ccem-font-mono, monospace); font-size: 11px; color: var(--ccem-fg-dim);">
                    {agent_role(agent) || "—"}
                  </span>
                </:col>
                <:col :let={agent} label="Status">
                  <.badge tone={status_tone(agent_status(agent))} dot={agent_status(agent) == "active"}>
                    {String.capitalize(agent_status(agent))}
                  </.badge>
                </:col>
                <:col :let={agent} label="Tokens">
                  <span style="font-family: var(--ccem-font-mono, monospace); font-size: 12px; font-variant-numeric: tabular-nums; color: var(--ccem-fg);">
                    {format_tokens(agent)}
                  </span>
                </:col>
                <:col :let={agent} label="Activity">
                  <.sparkline
                    data={agent.sparkline_data}
                    live_dot={agent_status(agent) == "active"}
                    width={80}
                    height={20}
                  />
                </:col>
                <:col :let={agent} label="Last Active">
                  <span style="font-size: 12px; color: var(--ccem-fg-muted);">
                    {format_last_active(agent)}
                  </span>
                </:col>
              </.data_table>
            </.card>
          <% end %>
        <% end %>
      </:main>

      <:inspector>
        <.inspector_panel
          open={@inspector_open}
          mode={@inspector_mode}
          on_close="toggle_inspector"
        >
          <:selection>
            <%= if @selected_agent do %>
              <div style="display: flex; flex-direction: column; gap: 12px;">
                <%!-- Identity block --%>
                <div>
                  <div style="font-size: 13px; font-weight: 600; color: var(--ccem-fg); margin-bottom: 2px;">
                    {agent_name(@selected_agent)}
                  </div>
                  <div style="font-family: var(--ccem-font-mono, monospace); font-size: 10px; color: var(--ccem-fg-dim); word-break: break-all;">
                    {to_string(@selected_agent.id)}
                  </div>
                </div>

                <%!-- Status badge --%>
                <div>
                  <.badge tone={status_tone(agent_status(@selected_agent))} dot={agent_status(@selected_agent) == "active"}>
                    {String.capitalize(agent_status(@selected_agent))}
                  </.badge>
                </div>

                <%!-- Sparkline --%>
                <div style="border: 1px solid var(--ccem-line); border-radius: 6px; padding: 10px;">
                  <div style="font-size: 10px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--ccem-fg-dim); margin-bottom: 6px;">Activity</div>
                  <.sparkline
                    data={@selected_agent.sparkline_data}
                    live_dot={agent_status(@selected_agent) == "active"}
                    width={220}
                    height={40}
                  />
                </div>

                <%!-- Metadata rows --%>
                <div style="display: flex; flex-direction: column; gap: 8px;">
                  <.inspector_row label="Role" value={agent_role(@selected_agent) || "—"} />
                  <.inspector_row label="Formation" value={Map.get(@selected_agent, :formation_id, "—") |> to_string()} />
                  <.inspector_row label="Wave" value={Map.get(@selected_agent, :wave, Map.get(@selected_agent, :wave_number, "—")) |> to_string()} />
                  <.inspector_row label="Tokens" value={format_tokens(@selected_agent)} mono />
                  <.inspector_row label="Last Active" value={format_last_active(@selected_agent)} />
                </div>

                <%!-- Project tag if present --%>
                <%= if project = Map.get(@selected_agent, :project) || Map.get(@selected_agent, :project_name) do %>
                  <div>
                    <div style="font-size: 10px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--ccem-fg-dim); margin-bottom: 4px;">Project</div>
                    <.badge tone="iris">{project}</.badge>
                  </div>
                <% end %>
              </div>
            <% else %>
              <p style="font-size: 13px; color: var(--ccem-fg-dim); margin: 0;">
                Select an agent to view details.
              </p>
            <% end %>
          </:selection>

          <:copilot>
            <p style="font-size: 13px; color: var(--ccem-fg-dim); margin: 0;">
              Fleet AI co-pilot coming soon.
            </p>
          </:copilot>

          <:filters>
            <div style="display: flex; flex-direction: column; gap: 12px;">
              <div>
                <div style="font-size: 11px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--ccem-fg-dim); margin-bottom: 6px;">Status</div>
                <div style="display: flex; flex-direction: column; gap: 4px;">
                  <%= for status <- @status_filters do %>
                    <button
                      phx-click="set_status_filter"
                      phx-value-status={status}
                      style={
                        "text-align: left; padding: 4px 8px; font-size: 12px; border-radius: 4px; cursor: pointer; border: none; " <>
                          if(@status_filter == status,
                            do: "background: var(--ccem-bg-3); color: var(--ccem-fg); font-weight: 500;",
                            else: "background: transparent; color: var(--ccem-fg-muted);"
                          )
                      }
                    >
                      {status}
                    </button>
                  <% end %>
                </div>
              </div>
            </div>
          </:filters>
        </.inspector_panel>
      </:inspector>
    </.page_layout>
    """
  end

  # ---------------------------------------------------------------------------
  # Private components
  # ---------------------------------------------------------------------------

  # Inline helper component for inspector key-value rows.
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :mono, :boolean, default: false

  defp inspector_row(assigns) do
    ~H"""
    <div style="display: flex; justify-content: space-between; align-items: baseline; gap: 8px;">
      <span style="font-size: 11px; color: var(--ccem-fg-dim); flex-shrink: 0;">{@label}</span>
      <span style={
        "font-size: 12px; color: var(--ccem-fg); text-align: right; word-break: break-all; " <>
          if(@mono, do: "font-family: var(--ccem-font-mono, monospace); font-variant-numeric: tabular-nums;", else: "")
      }>
        {@value}
      </span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers — data loading
  # ---------------------------------------------------------------------------

  @spec load_agents() :: [map()]
  defp load_agents do
    try do
      AgentRegistry.list_agents()
      |> Enum.map(&enrich_agent/1)
    rescue
      _ -> []
    end
  end

  # Enrich a raw agent map with derived fields used by the UI.
  @spec enrich_agent(map()) :: map()
  defp enrich_agent(agent) do
    agent
    |> Map.put_new(:id, Map.get(agent, :agent_id, "unknown"))
    |> Map.put_new(:sparkline_data, generate_sparkline(agent))
  end

  # Generate a synthetic sparkline from agent token/activity data if available,
  # otherwise return a flat line to avoid empty sparklines.
  @spec generate_sparkline(map()) :: [number()]
  defp generate_sparkline(agent) do
    case Map.get(agent, :token_history) do
      data when is_list(data) and length(data) >= 2 -> Enum.take(data, 60)
      _ ->
        # Derive from token count as a single-bar pseudo-history
        tokens = Map.get(agent, :tokens, Map.get(agent, :token_count, 0)) || 0
        base = max(tokens, 1)
        # 12-point flat line at relative magnitude; gives a stable sparkline
        List.duplicate(base, 12)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers — filtering
  # ---------------------------------------------------------------------------

  @spec filter_agents([map()], String.t(), String.t()) :: [map()]
  defp filter_agents(agents, filter, status_filter) do
    agents
    |> filter_by_query(filter)
    |> filter_by_status(status_filter)
  end

  @spec filter_by_query([map()], String.t()) :: [map()]
  defp filter_by_query(agents, ""), do: agents

  defp filter_by_query(agents, query) do
    q = String.downcase(query)

    Enum.filter(agents, fn agent ->
      name = agent_name(agent) |> String.downcase()
      id = to_string(agent.id) |> String.downcase()
      role = (agent_role(agent) || "") |> String.downcase()
      String.contains?(name, q) or String.contains?(id, q) or String.contains?(role, q)
    end)
  end

  @spec filter_by_status([map()], String.t()) :: [map()]
  defp filter_by_status(agents, "All"), do: agents

  defp filter_by_status(agents, status) do
    Enum.filter(agents, fn agent -> agent_status(agent) == status end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers — agent field accessors
  # ---------------------------------------------------------------------------

  @spec agent_name(map()) :: String.t()
  defp agent_name(agent) do
    Map.get(agent, :name) ||
      Map.get(agent, :agent_id, "") |> to_string() |> truncate_id()
  end

  @spec agent_role(map()) :: String.t() | nil
  defp agent_role(agent) do
    Map.get(agent, :role) || Map.get(agent, :formation_role)
  end

  @spec agent_status(map()) :: String.t()
  defp agent_status(agent) do
    Map.get(agent, :status, "idle") |> to_string()
  end

  @spec format_tokens(map()) :: String.t()
  defp format_tokens(agent) do
    tokens = Map.get(agent, :tokens, Map.get(agent, :token_count, nil))

    case tokens do
      nil -> "—"
      n when is_integer(n) and n >= 1_000_000 -> "#{Float.round(n / 1_000_000, 1)}M"
      n when is_integer(n) and n >= 1_000 -> "#{Float.round(n / 1_000, 1)}K"
      n when is_integer(n) -> to_string(n)
      _ -> "—"
    end
  end

  @spec format_last_active(map()) :: String.t()
  defp format_last_active(agent) do
    case Map.get(agent, :last_active) || Map.get(agent, :updated_at) || Map.get(agent, :registered_at) do
      nil ->
        "—"

      %DateTime{} = dt ->
        relative_time(dt)

      iso when is_binary(iso) ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _} -> relative_time(dt)
          _ -> iso
        end

      _ ->
        "—"
    end
  end

  @spec relative_time(DateTime.t()) :: String.t()
  defp relative_time(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3_600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3_600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  @spec count_by_status([map()], String.t()) :: non_neg_integer()
  defp count_by_status(agents, status) do
    Enum.count(agents, fn a -> agent_status(a) == status end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers — DS mapping
  # ---------------------------------------------------------------------------

  @spec status_tone(String.t()) :: String.t()
  defp status_tone("active"), do: "success"
  defp status_tone("error"), do: "error"
  defp status_tone("done"), do: "iris"
  defp status_tone(_), do: "neutral"

  @spec status_filter_style(String.t(), String.t()) :: String.t()
  defp status_filter_style(active, option) when active == option do
    "background: var(--ccem-bg-3); color: var(--ccem-fg); border-color: var(--ccem-line);"
  end

  defp status_filter_style(_active, _option) do
    "background: transparent; color: var(--ccem-fg-dim); border-color: transparent;"
  end

  # ---------------------------------------------------------------------------
  # Private helpers — identicon (mirrors AiComponents.identicon_cells/1)
  # ---------------------------------------------------------------------------

  @spec identicon_cells(String.t()) :: list({integer(), integer(), boolean()})
  defp identicon_cells(agent_id) do
    hash =
      :crypto.hash(:sha256, agent_id)
      |> :binary.bin_to_list()

    for row <- 0..4, col <- 0..4 do
      source_col = if col >= 3, do: 4 - col, else: col
      byte_index = rem(row * 3 + source_col, length(hash))
      on = Enum.at(hash, byte_index) > 127
      {row, col, on}
    end
  end

  @spec truncate_id(String.t()) :: String.t()
  defp truncate_id(""), do: "unknown"
  defp truncate_id(id) when byte_size(id) > 20, do: String.slice(id, 0, 20) <> "…"
  defp truncate_id(id), do: id

end
