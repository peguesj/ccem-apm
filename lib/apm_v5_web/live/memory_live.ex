defmodule ApmV5Web.MemoryLive do
  @moduledoc """
  LiveView for the Memory observation browser.

  Provides three tabs for interacting with the claude-mem backend via
  `MemoryClientBridge` and `ObservationCache`:

  - **Browse** — Paginated list of cached observations with type filter.
  - **Search** — Free-text search powered by `MemoryClientBridge.search/1`.
  - **Timeline** — Observations grouped by calendar date from
    `MemoryClientBridge.timeline/1`, with per-date collapse/expand.

  Subscribes to `"apm:memory"` PubSub for live cache updates.
  """

  use ApmV5Web, :live_view

  require Logger

  alias ApmV5.Plugins.Memory.ConversationMemoryCorrelator
  alias ApmV5.Plugins.Memory.MemoryClientBridge
  alias ApmV5.Plugins.Memory.MemoryPlugin
  alias ApmV5.Plugins.Memory.ObservationCache

  @pubsub_topic "apm:memory"
  @per_page 20

  # ── Mount ──────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic)
      send(self(), :load_related_sessions)
      send(self(), :hydrate_cache)
    end

    observations = ObservationCache.list(limit: @per_page, offset: 0)
    stats = ObservationCache.stats()

    socket =
      socket
      |> assign(:page_title, "Memory")
      |> assign(:tab, :browse)
      |> assign(:sidebar_collapsed, false)
      |> assign(:inspector_open, false)
      # browse tab state
      |> assign(:observations, observations)
      |> assign(:type_filter, "all")
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> assign(:total_count, stats[:count] || 0)
      # search tab state
      |> assign(:search_query, "")
      |> assign(:search_results, [])
      |> assign(:searching, false)
      # timeline tab state
      |> assign(:timeline_groups, [])
      |> assign(:timeline_loaded, false)
      |> assign(:collapsed_dates, MapSet.new())
      # detail panel
      |> assign(:selected_observation, nil)
      # related sessions (cross-reference)
      |> assign(:related_sessions, [])
      |> assign(:sessions_collapsed, false)
      # shared
      |> assign(:notification_count, 0)
      |> assign(:skill_count, 0)
      |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()

    {:ok, socket}
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav current_path="/memory" />
      </:sidebar>
      <:topbar>
        <.top_bar project_name="CCEM APM" />
      </:topbar>
      <:main>
        <div phx-window-keydown="keydown" style="display:flex;flex-direction:column;height:100%;overflow:hidden;">
          <%!-- Header --%>
          <div style="padding:1.5rem 1.5rem 0;">
            <h1 style="font-size:1.5rem;font-weight:700;color:var(--ccem-text-primary);">Memory</h1>
            <p style="font-size:0.875rem;color:var(--ccem-text-muted);margin-top:0.25rem;">
              Observation browser — {@total_count} cached entries
            </p>
          </div>

          <%!-- Tab bar --%>
          <div style="padding:0 1.5rem;margin-top:1rem;border-bottom:1px solid var(--ccem-border);display:flex;gap:0.25rem;flex-shrink:0;">
            <%= for {tab_key, tab_label} <- [browse: "Browse", search: "Search", timeline: "Timeline"] do %>
              <button
                phx-click="switch_tab"
                phx-value-tab={tab_key}
                style={"padding:0.5rem 0.75rem;font-size:0.875rem;font-weight:500;border-bottom:2px solid #{if @tab == tab_key, do: "var(--ccem-accent)", else: "transparent"};color:#{if @tab == tab_key, do: "var(--ccem-accent)", else: "var(--ccem-text-muted)"};background:none;cursor:pointer;white-space:nowrap;"}
              >
                {tab_label}
              </button>
            <% end %>
          </div>

          <%!-- Tab content --%>
          <div style="flex:1;overflow-y:auto;padding:1.5rem;">

            <%!-- Browse tab --%>
            <div :if={@tab == :browse}>
              <%!-- Filters --%>
              <div style="display:flex;align-items:center;gap:0.75rem;margin-bottom:1rem;">
                <span style="font-size:0.875rem;color:var(--ccem-text-muted);">Type:</span>
                <select
                  style="font-size:0.875rem;padding:0.25rem 0.5rem;border:1px solid var(--ccem-border);border-radius:0.25rem;background:var(--ccem-bg-secondary);color:var(--ccem-text-primary);"
                  phx-change="filter_type"
                  name="type_filter"
                >
                  <option value="all" selected={@type_filter == "all"}>All</option>
                  <option value="agent" selected={@type_filter == "agent"}>agent</option>
                  <option value="tool_call" selected={@type_filter == "tool_call"}>tool_call</option>
                  <option value="session" selected={@type_filter == "session"}>session</option>
                  <option value="error" selected={@type_filter == "error"}>error</option>
                  <option value="security" selected={@type_filter == "security"}>security</option>
                  <option value="memory" selected={@type_filter == "memory"}>memory</option>
                </select>
              </div>

              <div :if={@observations == []} style="text-align:center;padding:3rem 0;color:var(--ccem-text-muted);">
                <p style="font-weight:500;">No observations in cache</p>
                <p style="font-size:0.875rem;margin-top:0.25rem;">Observations will appear as agents run</p>
              </div>

              <div :if={@observations != []} style="display:flex;flex-direction:column;gap:0.5rem;">
                <.observation_card :for={obs <- @observations} obs={obs} />
              </div>

              <%!-- Pagination --%>
              <div :if={@observations != []} style="display:flex;align-items:center;justify-content:space-between;margin-top:1rem;">
                <span style="font-size:0.875rem;color:var(--ccem-text-muted);">Page {@page}</span>
                <div style="display:flex;gap:0.5rem;">
                  <.btn variant="ghost" size="sm" phx-click="prev_page">Previous</.btn>
                  <.btn variant="ghost" size="sm" phx-click="next_page">Next</.btn>
                </div>
              </div>

              <%!-- Related Sessions cross-reference --%>
              <div style="margin-top:2rem;border-top:1px solid var(--ccem-border);padding-top:1rem;">
                <div
                  style="display:flex;align-items:center;gap:0.5rem;cursor:pointer;user-select:none;margin-bottom:0.5rem;"
                  phx-click="toggle_sessions_section"
                >
                  <span style={"display:inline-block;transition:transform 0.15s;transform:#{if @sessions_collapsed, do: "rotate(0deg)", else: "rotate(90deg)"};font-size:0.75rem;color:var(--ccem-text-muted);"}>&#9654;</span>
                  <span style="font-size:0.875rem;font-weight:600;color:var(--ccem-text-secondary,var(--ccem-text-muted));">Related Sessions</span>
                  <.badge tone="neutral">{length(@related_sessions)}</.badge>
                </div>

                <div :if={!@sessions_collapsed}>
                  <div :if={@related_sessions == []} style="font-size:0.875rem;color:var(--ccem-text-muted);padding:0.75rem 0 0.75rem 1.5rem;">
                    No related sessions found for the current project
                  </div>
                  <div :if={@related_sessions != []} style="display:flex;flex-direction:column;gap:0.5rem;padding-left:1.5rem;">
                    <.link
                      :for={sess <- @related_sessions}
                      navigate={"/conversations"}
                      style="display:flex;align-items:center;gap:0.75rem;background:var(--ccem-bg-secondary);border-radius:0.5rem;padding:0.5rem 0.75rem;text-decoration:none;"
                    >
                      <div style="flex:1;min-width:0;">
                        <p style="font-size:0.875rem;font-family:monospace;color:var(--ccem-text-primary);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">
                          {sess.session_id}
                        </p>
                        <p style="font-size:0.75rem;color:var(--ccem-text-muted);margin-top:0.125rem;">
                          {sess.started_at}
                        </p>
                      </div>
                      <.badge tone="iris">{sess.observation_count} obs</.badge>
                    </.link>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Search tab --%>
            <div :if={@tab == :search}>
              <form phx-submit="do_search" style="display:flex;gap:0.5rem;margin-bottom:1.5rem;">
                <div style="flex:1;">
                  <.ds_input
                    type="search"
                    name="query"
                    value={@search_query}
                    placeholder="Search observations..."
                  />
                </div>
                <.btn variant="primary" size="md">
                  <span :if={!@searching}>Search</span>
                  <span :if={@searching}>Searching...</span>
                </.btn>
              </form>

              <div
                :if={@search_query == "" && !@searching}
                style="text-align:center;padding:3rem 0;color:var(--ccem-text-muted);"
              >
                <p style="font-size:0.875rem;">Enter a query above to search observations</p>
              </div>

              <div :if={@searching} style="text-align:center;padding:3rem 0;color:var(--ccem-text-muted);">
                <p style="font-size:0.875rem;margin-top:0.5rem;">Searching...</p>
              </div>

              <div
                :if={!@searching && @search_query != "" && @search_results == []}
                style="text-align:center;padding:3rem 0;color:var(--ccem-text-muted);"
              >
                <p style="font-weight:500;">No results for "{@search_query}"</p>
              </div>

              <div :if={!@searching && @search_results != []} style="display:flex;flex-direction:column;gap:0.5rem;">
                <p style="font-size:0.875rem;color:var(--ccem-text-muted);margin-bottom:0.5rem;">
                  {length(@search_results)} result(s) for "{@search_query}"
                </p>
                <.observation_card :for={obs <- @search_results} obs={obs} />
              </div>
            </div>

            <%!-- Timeline tab --%>
            <div :if={@tab == :timeline}>
              <div :if={!@timeline_loaded} style="text-align:center;padding:3rem 0;color:var(--ccem-text-muted);">
                <p style="font-size:0.875rem;margin-top:0.5rem;">Loading timeline...</p>
              </div>

              <div :if={@timeline_loaded && @timeline_groups == []} style="text-align:center;padding:3rem 0;color:var(--ccem-text-muted);">
                <p style="font-weight:500;">No timeline data available</p>
                <p style="font-size:0.875rem;margin-top:0.25rem;">Timeline requires the claude-mem worker to be running</p>
              </div>

              <div :if={@timeline_loaded && @timeline_groups != []} style="display:flex;flex-direction:column;gap:1rem;">
                <div :for={{date_label, group_obs} <- @timeline_groups}>
                  <%!-- Date header --%>
                  <div
                    style="display:flex;align-items:center;gap:0.5rem;cursor:pointer;user-select:none;"
                    phx-click="toggle_date"
                    phx-value-date={date_label}
                  >
                    <span style={"display:inline-block;transition:transform 0.15s;transform:#{if MapSet.member?(@collapsed_dates, date_label), do: "rotate(0deg)", else: "rotate(90deg)"};font-size:0.75rem;color:var(--ccem-text-muted);"}>&#9654;</span>
                    <span style="font-size:1rem;font-weight:600;color:var(--ccem-text-primary);">{date_label}</span>
                    <.badge tone="neutral">{length(group_obs)}</.badge>
                  </div>

                  <%!-- Observations under this date --%>
                  <div
                    :if={!MapSet.member?(@collapsed_dates, date_label)}
                    style="margin-left:1.5rem;display:flex;flex-direction:column;gap:0.5rem;margin-top:0.5rem;"
                  >
                    <.observation_card :for={obs <- group_obs} obs={obs} />
                  </div>
                </div>
              </div>
            </div>

          </div>
        </div>

        <%!-- Observation detail slide-out panel --%>
        <div
          :if={@selected_observation != nil}
          style="position:fixed;inset:0;z-index:50;display:flex;"
        >
          <%!-- Backdrop --%>
          <div
            style="position:fixed;inset:0;background:rgba(0,0,0,0.4);"
            phx-click="close_detail"
          ></div>

          <%!-- Panel --%>
          <div style="position:relative;margin-left:auto;width:100%;max-width:32rem;background:var(--ccem-bg-secondary);display:flex;flex-direction:column;overflow:hidden;box-shadow:0 25px 50px -12px rgba(0,0,0,0.25);">
            <%!-- Title bar --%>
            <div style="display:flex;align-items:center;justify-content:space-between;padding:1rem 1.25rem;border-bottom:1px solid var(--ccem-border);">
              <div style="display:flex;align-items:center;gap:0.5rem;">
                <.type_badge type={observation_type(@selected_observation)} />
                <span style="font-size:0.875rem;font-weight:600;color:var(--ccem-text-primary);">Observation Detail</span>
              </div>
              <.btn variant="ghost" size="sm" phx-click="close_detail">X</.btn>
            </div>

            <%!-- Body --%>
            <div style="flex:1;overflow-y:auto;padding:1rem 1.25rem;display:flex;flex-direction:column;gap:1.25rem;">
              <%!-- ID --%>
              <div>
                <p style="font-size:0.75rem;font-weight:500;color:var(--ccem-text-muted);text-transform:uppercase;letter-spacing:0.05em;margin-bottom:0.25rem;">ID</p>
                <p style="font-size:0.875rem;font-family:monospace;color:var(--ccem-text-primary);word-break:break-all;">
                  {Map.get(@selected_observation, "id") || Map.get(@selected_observation, :id) || "—"}
                </p>
              </div>

              <%!-- Source --%>
              <div>
                <p style="font-size:0.75rem;font-weight:500;color:var(--ccem-text-muted);text-transform:uppercase;letter-spacing:0.05em;margin-bottom:0.25rem;">Source</p>
                <p style="font-size:0.875rem;color:var(--ccem-text-primary);">
                  {to_string(Map.get(@selected_observation, "source") || Map.get(@selected_observation, :source) || "—")}
                </p>
              </div>

              <%!-- Timestamp --%>
              <div>
                <p style="font-size:0.75rem;font-weight:500;color:var(--ccem-text-muted);text-transform:uppercase;letter-spacing:0.05em;margin-bottom:0.25rem;">Timestamp</p>
                <p style="font-size:0.875rem;font-family:monospace;color:var(--ccem-text-primary);">
                  {observation_timestamp(@selected_observation)}
                </p>
              </div>

              <%!-- Tags --%>
              <div>
                <p style="font-size:0.75rem;font-weight:500;color:var(--ccem-text-muted);text-transform:uppercase;letter-spacing:0.05em;margin-bottom:0.25rem;">Tags</p>
                <div style="display:flex;flex-wrap:wrap;gap:0.25rem;">
                  <%= for tag <- (Map.get(@selected_observation, "tags") || Map.get(@selected_observation, :tags) || []) do %>
                    <.badge tone="neutral">{tag}</.badge>
                  <% end %>
                  <span
                    :if={(Map.get(@selected_observation, "tags") || Map.get(@selected_observation, :tags) || []) == []}
                    style="font-size:0.875rem;color:var(--ccem-text-muted);"
                  >
                    None
                  </span>
                </div>
              </div>

              <%!-- Content / narrative --%>
              <div>
                <p style="font-size:0.75rem;font-weight:500;color:var(--ccem-text-muted);text-transform:uppercase;letter-spacing:0.05em;margin-bottom:0.25rem;">Content</p>
                <pre style="font-size:0.875rem;color:var(--ccem-text-primary);background:var(--ccem-bg-tertiary,var(--ccem-bg-secondary));border-radius:0.5rem;padding:0.75rem;white-space:pre-wrap;word-break:break-words;line-height:1.625;max-height:20rem;overflow-y:auto;">
                  {Map.get(@selected_observation, "narrative") || Map.get(@selected_observation, :narrative) || "(no content)"}
                </pre>
              </div>
            </div>
          </div>
        </div>
      </:main>
      <:inspector>
        <div style="padding:1rem;color:var(--ccem-text-muted);font-size:0.875rem;">
          <p>Select an observation to inspect details.</p>
        </div>
      </:inspector>
    </.page_layout>
    """
  end

  # ── Components ─────────────────────────────────────────────────────────────

  defp observation_card(assigns) do
    obs_id = Map.get(assigns.obs, "id") || Map.get(assigns.obs, :id) || ""
    assigns = assign(assigns, :obs_id, obs_id)

    ~H"""
    <.card padded={true}>
      <div
        style="cursor:pointer;"
        phx-click="select_observation"
        phx-value-id={@obs_id}
      >
        <div style="display:flex;align-items:flex-start;gap:0.75rem;">
          <.type_badge type={observation_type(@obs)} />
          <div style="flex:1;min-width:0;">
            <p style="font-size:0.875rem;color:var(--ccem-text-primary);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">
              {truncate(observation_narrative(@obs), 120)}
            </p>
            <p style="font-size:0.75rem;color:var(--ccem-text-muted);margin-top:0.125rem;">
              {observation_timestamp(@obs)}
            </p>
          </div>
        </div>
      </div>
    </.card>
    """
  end

  defp type_badge(assigns) do
    {tone, label} = type_style(assigns.type)
    assigns = assign(assigns, tone: tone, label: label)

    ~H"""
    <.badge tone={@tone}>{@label}</.badge>
    """
  end

  defp type_style("agent"), do: {"accent", "agent"}
  defp type_style("tool_call"), do: {"info", "tool_call"}
  defp type_style("session"), do: {"iris", "session"}
  defp type_style("error"), do: {"error", "error"}
  defp type_style("security"), do: {"warning", "security"}
  defp type_style("memory"), do: {"success", "memory"}
  defp type_style(other), do: {"neutral", other || "unknown"}

  # ── Event Handlers ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("switch_tab", %{"tab" => "browse"}, socket) do
    observations = load_observations(socket.assigns)
    {:noreply, assign(socket, tab: :browse, observations: observations)}
  end

  def handle_event("switch_tab", %{"tab" => "search"}, socket) do
    {:noreply, assign(socket, :tab, :search)}
  end

  def handle_event("switch_tab", %{"tab" => "timeline"}, socket) do
    socket = assign(socket, tab: :timeline, timeline_loaded: false)
    send(self(), :load_timeline)
    {:noreply, socket}
  end

  def handle_event("filter_type", %{"type_filter" => type}, socket) do
    socket =
      socket
      |> assign(:type_filter, type)
      |> assign(:page, 1)

    observations = load_observations(socket.assigns)
    {:noreply, assign(socket, :observations, observations)}
  end

  def handle_event("prev_page", _params, socket) do
    page = max(1, socket.assigns.page - 1)
    socket = assign(socket, :page, page)
    observations = load_observations(socket.assigns)
    {:noreply, assign(socket, :observations, observations)}
  end

  def handle_event("next_page", _params, socket) do
    page = socket.assigns.page + 1
    socket = assign(socket, :page, page)
    observations = load_observations(socket.assigns)
    {:noreply, assign(socket, :observations, observations)}
  end

  def handle_event("do_search", %{"query" => query}, socket) do
    socket =
      socket
      |> assign(:search_query, query)
      |> assign(:searching, true)
      |> assign(:search_results, [])

    send(self(), {:run_search, query})
    {:noreply, socket}
  end

  def handle_event("toggle_date", %{"date" => date_label}, socket) do
    collapsed =
      if MapSet.member?(socket.assigns.collapsed_dates, date_label) do
        MapSet.delete(socket.assigns.collapsed_dates, date_label)
      else
        MapSet.put(socket.assigns.collapsed_dates, date_label)
      end

    {:noreply, assign(socket, :collapsed_dates, collapsed)}
  end

  def handle_event("select_observation", %{"id" => id}, socket) do
    socket =
      case MemoryPlugin.handle_action("get_observation", %{"id" => id}, []) do
        {:ok, %{observation: obs}} ->
          assign(socket, :selected_observation, obs)

        {:error, reason} ->
          Logger.warning("[MemoryLive] Failed to fetch observation #{id}: #{inspect(reason)}")
          socket
      end

    {:noreply, socket}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, :selected_observation, nil)}
  end

  def handle_event("toggle_sessions_section", _params, socket) do
    {:noreply, assign(socket, :sessions_collapsed, !socket.assigns.sessions_collapsed)}
  end

  def handle_event("keydown", %{"key" => "Escape"}, socket) do
    {:noreply, assign(socket, :selected_observation, nil)}
  end

  def handle_event("keydown", _params, socket), do: {:noreply, socket}

  # ── PubSub / Internal Messages ─────────────────────────────────────────────

  @impl true
  def handle_info({:observations_updated, _count}, socket) do
    stats = ObservationCache.stats()
    socket = assign(socket, :total_count, stats[:count] || 0)

    socket =
      if socket.assigns.tab == :browse do
        socket
        |> assign(:observations, load_observations(socket.assigns))
        |> load_related_sessions()
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(:hydrate_cache, socket) do
    cached = ObservationCache.list(limit: 1)

    if cached == [] do
      case MemoryClientBridge.timeline() do
        {:ok, observations} when observations != [] ->
          ObservationCache.refresh(observations)
          page_obs = Enum.take(observations, socket.assigns.per_page)
          stats = ObservationCache.stats()

          {:noreply,
           socket
           |> assign(:observations, page_obs)
           |> assign(:total_count, stats[:count] || length(observations))}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(:load_related_sessions, socket) do
    {:noreply, load_related_sessions(socket)}
  end

  def handle_info({:run_search, query}, socket) do
    results =
      case MemoryClientBridge.search(query) do
        {:ok, list} -> list
        {:error, _} -> ObservationCache.search(query)
      end

    {:noreply,
     socket
     |> assign(:search_results, results)
     |> assign(:searching, false)}
  end

  def handle_info(:load_timeline, socket) do
    groups =
      case MemoryClientBridge.timeline() do
        {:ok, observations} -> group_by_date(observations)
        {:error, _} -> []
      end

    {:noreply,
     socket
     |> assign(:timeline_groups, groups)
     |> assign(:timeline_loaded, true)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp load_observations(%{page: page, per_page: per_page, type_filter: type_filter}) do
    offset = (page - 1) * per_page
    all = ObservationCache.list(limit: per_page * page, offset: 0)

    all
    |> filter_by_type(type_filter)
    |> Enum.drop(offset)
    |> Enum.take(per_page)
  end

  defp filter_by_type(observations, "all"), do: observations

  defp filter_by_type(observations, type) do
    Enum.filter(observations, fn obs -> observation_type(obs) == type end)
  end

  defp group_by_date(observations) do
    observations
    |> Enum.group_by(fn obs -> date_label_for(obs) end)
    |> Enum.sort_by(fn {label, _} -> label end, :desc)
  end

  defp date_label_for(obs) do
    case Map.get(obs, "timestamp") || Map.get(obs, :timestamp) do
      nil ->
        "Unknown Date"

      ts when is_binary(ts) ->
        case DateTime.from_iso8601(ts) do
          {:ok, dt, _} -> Calendar.strftime(dt, "%B %d, %Y")
          _ -> "Unknown Date"
        end

      %DateTime{} = dt ->
        Calendar.strftime(dt, "%B %d, %Y")

      _ ->
        "Unknown Date"
    end
  end

  defp observation_type(obs) do
    to_string(Map.get(obs, "observation_type") || Map.get(obs, :observation_type) || "unknown")
  end

  defp observation_narrative(obs) do
    Map.get(obs, "narrative") || Map.get(obs, :narrative) || "(no narrative)"
  end

  defp observation_timestamp(obs) do
    case Map.get(obs, "timestamp") || Map.get(obs, :timestamp) do
      nil -> ""
      ts when is_binary(ts) -> ts
      %DateTime{} = dt -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> ""
    end
  end

  defp load_related_sessions(socket) do
    project_path = File.cwd!()

    sessions =
      case ConversationMemoryCorrelator.correlate_project(project_path) do
        {:ok, observations} ->
          observations
          |> Enum.group_by(fn obs ->
            obs["session_id"] || obs[:session_id] || "unknown"
          end)
          |> Enum.map(fn {session_id, obs_list} ->
            started_at =
              obs_list
              |> Enum.map(fn o -> o["timestamp"] || o[:timestamp] end)
              |> Enum.reject(&is_nil/1)
              |> Enum.sort()
              |> List.first()
              |> format_related_ts()

            %{
              session_id: session_id,
              started_at: started_at,
              observation_count: length(obs_list)
            }
          end)
          |> Enum.sort_by(& &1.started_at, :desc)

        _ ->
          []
      end

    assign(socket, :related_sessions, sessions)
  end

  defp format_related_ts(nil), do: "unknown"

  defp format_related_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
      _ -> ts
    end
  end

  defp format_related_ts(_), do: "unknown"

  defp truncate(text, max) when is_binary(text) and byte_size(text) > max do
    String.slice(text, 0, max) <> "..."
  end

  defp truncate(text, _max), do: text
end
