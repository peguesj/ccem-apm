defmodule ApmV5Web.LibraryLive do
  # Author: Jeremiah Pegues <jeremiah@pegues.io>
  @moduledoc """
  LiveView dashboard for the CCEM Libraries catalog.

  Displays all ecosystem resources across 7 tabs:
  Agents | Skills | MCP | Tools | Commands | Patterns | Learnings

  Each tab shows a searchable card grid with badge counts in tab headers.
  Clicking a card opens a detail drawer on the right.

  Subscribes to `"apm:library"` PubSub and refreshes every 30 seconds.
  """

  use ApmV5Web, :live_view

  alias ApmV5.LibraryStore

  @refresh_interval 30_000

  @tabs ~w(agents skills mcp tools commands patterns learnings)a

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:library")
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end

    socket =
      socket
      |> assign(:page_title, "Library")
      |> assign(:active_nav, :library)
      |> assign(:tab, :agents)
      |> assign(:search_query, "")
      |> assign(:selected_item, nil)
      |> load_all_data()

    {:ok, socket |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  @impl true
  def handle_info({:library_updated, _summary}, socket) do
    {:noreply, load_all_data(socket)}
  end

  def handle_info(:refresh, socket) do
    {:noreply, load_all_data(socket)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab_atom = String.to_existing_atom(tab)

    socket =
      socket
      |> assign(:tab, tab_atom)
      |> assign(:search_query, "")
      |> assign(:selected_item, nil)

    {:noreply, socket}
  end

  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, assign(socket, :search_query, query)}
  end

  def handle_event("select_item", %{"idx" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    items = filtered_items(socket)
    selected = Enum.at(items, idx)

    current = socket.assigns.selected_item
    new_selected = if current == selected, do: nil, else: selected

    {:noreply, assign(socket, :selected_item, new_selected)}
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign(socket, :selected_item, nil)}
  end

  def handle_event("refresh_library", _params, socket) do
    LibraryStore.refresh()
    {:noreply, socket}
  end

  def handle_event("keydown", %{"key" => "Escape"}, socket) do
    {:noreply, assign(socket, :selected_item, nil)}
  end

  def handle_event("keydown", _params, socket), do: {:noreply, socket}

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :filtered, filtered_items(assigns))

    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden" phx-window-keydown="keydown">
      <nav aria-label="Main navigation">
        <.sidebar_nav current_path="/library" />
      </nav>

      <main class="flex-1 flex flex-col overflow-hidden">
        <%!-- Header --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0 relative z-10">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">CCEM Libraries</h2>
            <div class="badge badge-sm badge-ghost">{total_count(assigns)} resources</div>
          </div>
          <div class="flex items-center gap-2">
            <button phx-click="refresh_library" class="btn btn-ghost btn-xs">
              Refresh
            </button>
            <span class="text-xs text-base-content/40">Auto-refresh 30s</span>
          </div>
        </header>

        <%!-- Tab bar --%>
        <div class="bg-base-200 border-b border-base-300 px-4 flex items-center gap-1 overflow-x-auto flex-shrink-0">
          <%= for tab <- @tabs do %>
            <button
              phx-click="switch_tab"
              phx-value-tab={tab}
              class={[
                "px-3 py-2 text-xs font-medium border-b-2 transition-colors whitespace-nowrap",
                @tab == tab && "border-primary text-primary",
                @tab != tab && "border-transparent text-base-content/50 hover:text-base-content hover:border-base-content/20"
              ]}
            >
              {tab_label(tab)}
              <span class={[
                "ml-1 badge badge-xs",
                @tab == tab && "badge-primary",
                @tab != tab && "badge-ghost"
              ]}>
                {tab_count(assigns, tab)}
              </span>
            </button>
          <% end %>
        </div>

        <%!-- Search bar --%>
        <div class="bg-base-200/50 px-4 py-2 flex-shrink-0">
          <input
            type="text"
            placeholder={"Search #{tab_label(@tab)}..."}
            value={@search_query}
            phx-keyup="search"
            phx-value-query=""
            name="query"
            class="input input-sm input-bordered w-full max-w-sm bg-base-100"
            phx-debounce="300"
          />
        </div>

        <%!-- Content area --%>
        <div class="flex-1 flex overflow-hidden">
          <%!-- Card grid --%>
          <div class={[
            "overflow-y-auto p-4",
            @selected_item && "flex-1",
            !@selected_item && "flex-1"
          ]}>
            <div :if={@filtered == []} class="text-center py-12 text-base-content/40">
              <p class="text-lg">No {@tab} found</p>
              <p :if={@search_query != ""} class="text-sm mt-1">Try adjusting your search</p>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
              <%= for {item, idx} <- Enum.with_index(@filtered) do %>
                <div
                  phx-click="select_item"
                  phx-value-idx={idx}
                  class={[
                    "card bg-base-100 shadow-sm border border-base-300 cursor-pointer transition-all hover:shadow-md hover:border-primary/30",
                    @selected_item == item && "ring-2 ring-primary border-primary"
                  ]}
                >
                  <div class="card-body p-3">
                    <div class="flex items-start justify-between gap-2">
                      <h3 class="text-sm font-semibold text-base-content truncate">
                        {display_name(item)}
                      </h3>
                      {type_badge(assigns, item)}
                    </div>
                    <p class="text-xs text-base-content/60 line-clamp-2 mt-1">
                      {item_description(item)}
                    </p>
                    <div class="flex items-center gap-2 mt-2 text-[10px] text-base-content/40">
                      <span :if={item[:source]} class="truncate max-w-[200px]">{item[:source]}</span>
                      <span :if={item[:last_modified]} class="whitespace-nowrap">{relative_time(item[:last_modified])}</span>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Detail drawer --%>
          <aside
            :if={@selected_item}
            class="w-96 bg-base-100 border-l border-base-300 overflow-y-auto flex-shrink-0"
          >
            <div class="p-4">
              <div class="flex items-center justify-between mb-4">
                <h3 class="text-lg font-bold text-base-content truncate">
                  {display_name(@selected_item)}
                </h3>
                <button phx-click="close_drawer" class="btn btn-ghost btn-xs btn-circle">X</button>
              </div>

              {type_badge(assigns, @selected_item)}

              <div class="divider my-2"></div>

              <%!-- Description --%>
              <div class="mb-4">
                <h4 class="text-xs font-semibold text-base-content/50 uppercase mb-1">Description</h4>
                <p class="text-sm text-base-content/80">{item_description(@selected_item)}</p>
              </div>

              <%!-- Properties table --%>
              <div class="mb-4">
                <h4 class="text-xs font-semibold text-base-content/50 uppercase mb-1">Properties</h4>
                <div class="bg-base-200 rounded-lg p-3 space-y-2">
                  <%= for {key, val} <- detail_properties(@selected_item) do %>
                    <div class="flex items-start justify-between gap-2">
                      <span class="text-xs text-base-content/50 whitespace-nowrap">{key}</span>
                      <span class="text-xs text-base-content text-right break-all">{format_value(val)}</span>
                    </div>
                  <% end %>
                </div>
              </div>

              <%!-- Triggers (skills only) --%>
              <div :if={@tab == :skills and (@selected_item[:triggers] || []) != []} class="mb-4">
                <h4 class="text-xs font-semibold text-base-content/50 uppercase mb-1">Triggers</h4>
                <div class="space-y-1">
                  <%= for trigger <- @selected_item[:triggers] || [] do %>
                    <div class="text-xs bg-base-200 rounded px-2 py-1 text-base-content/70">{trigger}</div>
                  <% end %>
                </div>
              </div>

              <%!-- Related skills (patterns only) --%>
              <div :if={@tab == :patterns and (@selected_item[:related_skills] || []) != []} class="mb-4">
                <h4 class="text-xs font-semibold text-base-content/50 uppercase mb-1">Related Skills</h4>
                <div class="flex flex-wrap gap-1">
                  <%= for skill <- @selected_item[:related_skills] || [] do %>
                    <span class="badge badge-sm badge-outline">{skill}</span>
                  <% end %>
                </div>
              </div>
            </div>
          </aside>
        </div>
      </main>
    </div>
    """
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  defp load_all_data(socket) do
    socket
    |> assign(:agents_data, LibraryStore.list_agents())
    |> assign(:skills_data, LibraryStore.list_skills())
    |> assign(:mcp_data, LibraryStore.list_mcp_servers())
    |> assign(:tools_data, LibraryStore.list_tools())
    |> assign(:commands_data, LibraryStore.list_commands())
    |> assign(:patterns_data, LibraryStore.list_patterns())
    |> assign(:learnings_data, LibraryStore.list_learnings())
    |> assign(:tabs, @tabs)
  end

  defp items_for_tab(assigns, tab) do
    case tab do
      :agents -> assigns[:agents_data] || []
      :skills -> assigns[:skills_data] || []
      :mcp -> assigns[:mcp_data] || []
      :tools -> assigns[:tools_data] || []
      :commands -> assigns[:commands_data] || []
      :patterns -> assigns[:patterns_data] || []
      :learnings -> assigns[:learnings_data] || []
      _ -> []
    end
  end

  defp filtered_items(%{assigns: assigns}), do: filtered_items(assigns)
  defp filtered_items(assigns) do
    tab = assigns[:tab] || :agents
    query = assigns[:search_query] || ""
    items = items_for_tab(assigns, tab)

    if query == "" do
      items
    else
      lower_q = String.downcase(query)
      Enum.filter(items, fn item ->
        name = to_string(item[:name] || "") |> String.downcase()
        desc = to_string(item[:description] || "") |> String.downcase()
        display = to_string(item[:display_name] || "") |> String.downcase()
        String.contains?(name, lower_q) or
        String.contains?(desc, lower_q) or
        String.contains?(display, lower_q)
      end)
    end
  end

  defp total_count(assigns) do
    Enum.reduce(@tabs, 0, fn tab, acc -> acc + length(items_for_tab(assigns, tab)) end)
  end

  defp tab_count(assigns, tab), do: length(items_for_tab(assigns, tab))

  defp tab_label(:agents), do: "Agents"
  defp tab_label(:skills), do: "Skills"
  defp tab_label(:mcp), do: "MCP"
  defp tab_label(:tools), do: "Tools"
  defp tab_label(:commands), do: "Commands"
  defp tab_label(:patterns), do: "Patterns"
  defp tab_label(:learnings), do: "Learnings"
  defp tab_label(other), do: other |> to_string() |> String.capitalize()

  defp display_name(item) do
    item[:display_name] || item[:name] || "Unknown"
  end

  defp item_description(item) do
    desc = item[:description] || ""
    if desc == "", do: "No description available", else: desc
  end

  defp type_badge(assigns, item) do
    _ = assigns
    type = item[:type] || item[:category] || item[:scope] || nil
    if type do
      assigns = assign(assigns, :badge_type, type)

      ~H"""
      <span class={[
        "badge badge-xs whitespace-nowrap",
        badge_color(@badge_type)
      ]}>
        {@badge_type}
      </span>
      """
    else
      ~H""
    end
  end

  defp badge_color(type) when is_binary(type) do
    cond do
      type in ~w(orchestrator persistent_service) -> "badge-primary"
      type in ~w(squadron_lead quality_agent) -> "badge-secondary"
      type in ~w(swarm_agent cluster_agent) -> "badge-accent"
      type in ~w(agentlock security) -> "badge-error"
      type in ~w(methodology architecture) -> "badge-info"
      type in ~w(workflow documentation quality) -> "badge-success"
      type in ~w(user project enabled) -> "badge-warning"
      true -> "badge-ghost"
    end
  end
  defp badge_color(_), do: "badge-ghost"

  defp detail_properties(item) do
    item
    |> Map.to_list()
    |> Enum.reject(fn {k, _v} ->
      k in [:__struct__, :description, :display_name, :triggers, :related_skills]
    end)
    |> Enum.filter(fn {_k, v} -> v != nil and v != "" and v != [] end)
    |> Enum.map(fn {k, v} -> {k |> to_string() |> String.replace("_", " ") |> String.capitalize(), v} end)
    |> Enum.sort_by(fn {k, _v} -> k end)
  end

  defp format_value(val) when is_list(val), do: Enum.join(val, ", ")
  defp format_value(val) when is_map(val), do: inspect(val, pretty: true, limit: 5)
  defp format_value(val) when is_integer(val), do: Integer.to_string(val)
  defp format_value(val) when is_boolean(val), do: to_string(val)
  defp format_value(val), do: to_string(val)

  defp relative_time(nil), do: ""
  defp relative_time(iso_str) when is_binary(iso_str) do
    case DateTime.from_iso8601(iso_str) do
      {:ok, dt, _offset} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)
        cond do
          diff < 60 -> "just now"
          diff < 3600 -> "#{div(diff, 60)}m ago"
          diff < 86400 -> "#{div(diff, 3600)}h ago"
          diff < 604_800 -> "#{div(diff, 86400)}d ago"
          true -> "#{div(diff, 604_800)}w ago"
        end
      _ -> iso_str
    end
  end
  defp relative_time(_), do: ""
end
