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
    <div class="flex h-screen bg-base-100" phx-window-keydown="keydown">
      <ApmV5Web.Components.SidebarNav.sidebar_nav
        current_path="/memory"
        notification_count={@notification_count}
        skill_count={@skill_count}
        plugins={@plugins}
        integrations={@integrations}
      />
      <main class="flex-1 overflow-auto p-6">
        <div class="max-w-7xl mx-auto">
          <%!-- Header --%>
          <div class="flex items-center justify-between mb-6">
            <div>
              <h1 class="text-2xl font-bold text-base-content">Memory</h1>
              <p class="text-sm text-base-content/60 mt-1">
                Observation browser — {@total_count} cached entries
              </p>
            </div>
          </div>

          <%!-- Tab bar --%>
          <div class="tabs tabs-bordered mb-4">
            <a
              class={"tab #{if @tab == :browse, do: "tab-active"}"}
              phx-click="switch_tab"
              phx-value-tab="browse"
            >
              Browse
            </a>
            <a
              class={"tab #{if @tab == :search, do: "tab-active"}"}
              phx-click="switch_tab"
              phx-value-tab="search"
            >
              Search
            </a>
            <a
              class={"tab #{if @tab == :timeline, do: "tab-active"}"}
              phx-click="switch_tab"
              phx-value-tab="timeline"
            >
              Timeline
            </a>
          </div>

          <%!-- Browse tab --%>
          <div :if={@tab == :browse}>
            <%!-- Filters --%>
            <div class="flex items-center gap-3 mb-4">
              <label class="text-sm text-base-content/60">Type:</label>
              <select
                class="select select-sm select-bordered"
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

            <div :if={@observations == []} class="text-center py-12 text-base-content/40">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-12 w-12 mx-auto mb-3 opacity-30"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="1.5"
                  d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2"
                />
              </svg>
              <p class="font-medium">No observations in cache</p>
              <p class="text-sm mt-1">Observations will appear as agents run</p>
            </div>

            <div :if={@observations != []} class="space-y-2">
              <.observation_card :for={obs <- @observations} obs={obs} />
            </div>

            <%!-- Pagination --%>
            <div :if={@observations != []} class="flex items-center justify-between mt-4">
              <span class="text-sm text-base-content/50">
                Page {@page}
              </span>
              <div class="flex gap-2">
                <button
                  class="btn btn-sm btn-ghost"
                  phx-click="prev_page"
                  disabled={@page <= 1}
                >
                  Previous
                </button>
                <button
                  class="btn btn-sm btn-ghost"
                  phx-click="next_page"
                  disabled={length(@observations) < @per_page}
                >
                  Next
                </button>
              </div>
            </div>

            <%!-- Related Sessions cross-reference --%>
            <div class="mt-8 border-t border-base-300 pt-4">
              <div
                class="flex items-center gap-2 cursor-pointer select-none mb-2"
                phx-click="toggle_sessions_section"
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class={"h-4 w-4 transition-transform #{if @sessions_collapsed, do: "", else: "rotate-90"}"}
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M9 5l7 7-7 7"
                  />
                </svg>
                <h2 class="text-sm font-semibold text-base-content/70">Related Sessions</h2>
                <span class="badge badge-sm badge-ghost">{length(@related_sessions)}</span>
              </div>

              <div :if={!@sessions_collapsed}>
                <div :if={@related_sessions == []} class="text-sm text-base-content/40 py-3 pl-6">
                  No related sessions found for the current project
                </div>
                <div :if={@related_sessions != []} class="space-y-2 pl-6">
                  <.link
                    :for={sess <- @related_sessions}
                    navigate={"/conversations"}
                    class="flex items-center gap-3 bg-base-200 hover:bg-base-300 rounded-lg px-3 py-2 transition-colors cursor-pointer"
                  >
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      class="h-4 w-4 text-secondary shrink-0"
                      fill="none"
                      viewBox="0 0 24 24"
                      stroke="currentColor"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="1.5"
                        d="M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z"
                      />
                    </svg>
                    <div class="flex-1 min-w-0">
                      <p class="text-sm font-mono text-base-content truncate">
                        {sess.session_id}
                      </p>
                      <p class="text-xs text-base-content/40 mt-0.5">
                        {sess.started_at}
                      </p>
                    </div>
                    <span class="badge badge-sm badge-secondary shrink-0">
                      {sess.observation_count} obs
                    </span>
                  </.link>
                </div>
              </div>
            </div>
          </div>

          <%!-- Search tab --%>
          <div :if={@tab == :search}>
            <form phx-submit="do_search" class="flex gap-2 mb-6">
              <input
                type="text"
                name="query"
                value={@search_query}
                placeholder="Search observations..."
                class="input input-bordered flex-1"
                autofocus
              />
              <button type="submit" class="btn btn-primary" disabled={@searching}>
                <span :if={@searching} class="loading loading-spinner loading-sm"></span>
                <span :if={!@searching}>Search</span>
              </button>
            </form>

            <div
              :if={@search_query == "" && !@searching}
              class="text-center py-12 text-base-content/40"
            >
              <p class="text-sm">Enter a query above to search observations</p>
            </div>

            <div :if={@searching} class="text-center py-12 text-base-content/40">
              <span class="loading loading-dots loading-lg"></span>
              <p class="text-sm mt-2">Searching...</p>
            </div>

            <div
              :if={!@searching && @search_query != "" && @search_results == []}
              class="text-center py-12 text-base-content/40"
            >
              <p class="font-medium">No results for "{@search_query}"</p>
            </div>

            <div :if={!@searching && @search_results != []} class="space-y-2">
              <p class="text-sm text-base-content/50 mb-2">
                {length(@search_results)} result(s) for "{@search_query}"
              </p>
              <.observation_card :for={obs <- @search_results} obs={obs} />
            </div>
          </div>

          <%!-- Timeline tab --%>
          <div :if={@tab == :timeline}>
            <div :if={!@timeline_loaded} class="text-center py-12 text-base-content/40">
              <span class="loading loading-dots loading-lg"></span>
              <p class="text-sm mt-2">Loading timeline...</p>
            </div>

            <div :if={@timeline_loaded && @timeline_groups == []} class="text-center py-12 text-base-content/40">
              <p class="font-medium">No timeline data available</p>
              <p class="text-sm mt-1">Timeline requires the claude-mem worker to be running</p>
            </div>

            <div :if={@timeline_loaded && @timeline_groups != []} class="space-y-4">
              <div :for={{date_label, group_obs} <- @timeline_groups}>
                <%!-- Date header --%>
                <div
                  class="flex items-center gap-2 cursor-pointer select-none"
                  phx-click="toggle_date"
                  phx-value-date={date_label}
                >
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class={"h-4 w-4 transition-transform #{if MapSet.member?(@collapsed_dates, date_label), do: "", else: "rotate-90"}"}
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M9 5l7 7-7 7"
                    />
                  </svg>
                  <h2 class="text-base font-semibold text-base-content">{date_label}</h2>
                  <span class="badge badge-sm badge-ghost">{length(group_obs)}</span>
                </div>

                <%!-- Observations under this date --%>
                <div
                  :if={!MapSet.member?(@collapsed_dates, date_label)}
                  class="ml-6 space-y-2"
                >
                  <.observation_card :for={obs <- group_obs} obs={obs} />
                </div>
              </div>
            </div>
          </div>
        </div>
      </main>

      <%!-- Observation detail slide-out panel --%>
      <div
        :if={@selected_observation != nil}
        class="fixed inset-y-0 right-0 z-50 flex"
      >
        <%!-- Backdrop --%>
        <div
          class="fixed inset-0 bg-black/40"
          phx-click="close_detail"
        ></div>

        <%!-- Panel --%>
        <div class="relative ml-auto w-full max-w-lg bg-base-200 shadow-2xl flex flex-col overflow-hidden">
          <%!-- Title bar --%>
          <div class="flex items-center justify-between px-5 py-4 border-b border-base-300">
            <div class="flex items-center gap-2">
              <.type_badge type={observation_type(@selected_observation)} />
              <span class="text-sm font-semibold text-base-content">Observation Detail</span>
            </div>
            <button
              class="btn btn-sm btn-ghost btn-square"
              phx-click="close_detail"
              aria-label="Close"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-4 w-4"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M6 18L18 6M6 6l12 12"
                />
              </svg>
            </button>
          </div>

          <%!-- Body --%>
          <div class="flex-1 overflow-y-auto px-5 py-4 space-y-5">
            <%!-- ID --%>
            <div>
              <p class="text-xs font-medium text-base-content/50 uppercase tracking-wide mb-1">ID</p>
              <p class="text-sm font-mono text-base-content break-all">
                {Map.get(@selected_observation, "id") || Map.get(@selected_observation, :id) || "—"}
              </p>
            </div>

            <%!-- Source --%>
            <div>
              <p class="text-xs font-medium text-base-content/50 uppercase tracking-wide mb-1">Source</p>
              <p class="text-sm text-base-content">
                {to_string(Map.get(@selected_observation, "source") || Map.get(@selected_observation, :source) || "—")}
              </p>
            </div>

            <%!-- Timestamp --%>
            <div>
              <p class="text-xs font-medium text-base-content/50 uppercase tracking-wide mb-1">Timestamp</p>
              <p class="text-sm text-base-content font-mono">
                {observation_timestamp(@selected_observation)}
              </p>
            </div>

            <%!-- Tags --%>
            <div>
              <p class="text-xs font-medium text-base-content/50 uppercase tracking-wide mb-1">Tags</p>
              <div class="flex flex-wrap gap-1">
                <%= for tag <- (Map.get(@selected_observation, "tags") || Map.get(@selected_observation, :tags) || []) do %>
                  <span class="badge badge-sm badge-ghost font-mono">{tag}</span>
                <% end %>
                <span
                  :if={(Map.get(@selected_observation, "tags") || Map.get(@selected_observation, :tags) || []) == []}
                  class="text-sm text-base-content/40"
                >
                  None
                </span>
              </div>
            </div>

            <%!-- Content / narrative --%>
            <div>
              <p class="text-xs font-medium text-base-content/50 uppercase tracking-wide mb-1">Content</p>
              <pre class="text-sm text-base-content bg-base-300 rounded-lg p-3 whitespace-pre-wrap break-words leading-relaxed max-h-80 overflow-y-auto">
                {Map.get(@selected_observation, "narrative") || Map.get(@selected_observation, :narrative) || "(no content)"}
              </pre>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Components ─────────────────────────────────────────────────────────────

  defp observation_card(assigns) do
    obs_id = Map.get(assigns.obs, "id") || Map.get(assigns.obs, :id) || ""
    assigns = assign(assigns, :obs_id, obs_id)

    ~H"""
    <div
      class="card bg-base-200 shadow-sm cursor-pointer hover:bg-base-300 transition-colors"
      phx-click="select_observation"
      phx-value-id={@obs_id}
    >
      <div class="card-body p-3">
        <div class="flex items-start gap-3">
          <.type_badge type={observation_type(@obs)} />
          <div class="flex-1 min-w-0">
            <p class="text-sm text-base-content truncate">
              {truncate(observation_narrative(@obs), 120)}
            </p>
            <p class="text-xs text-base-content/40 mt-0.5">
              {observation_timestamp(@obs)}
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp type_badge(assigns) do
    {color, label} = type_style(assigns.type)
    assigns = assign(assigns, color: color, label: label)

    ~H"""
    <span class={"badge badge-sm shrink-0 #{@color}"}>{@label}</span>
    """
  end

  defp type_style("agent"), do: {"badge-primary", "agent"}
  defp type_style("tool_call"), do: {"badge-info", "tool_call"}
  defp type_style("session"), do: {"badge-secondary", "session"}
  defp type_style("error"), do: {"badge-error", "error"}
  defp type_style("security"), do: {"badge-warning", "security"}
  defp type_style("memory"), do: {"badge-accent", "memory"}
  defp type_style(other), do: {"badge-ghost", other || "unknown"}

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
