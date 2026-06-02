defmodule ApmWeb.LibraryLive do
  # Author: Jeremiah Pegues <jeremiah@pegues.io>
  @moduledoc """
  LiveView dashboard for the CCEM Libraries catalog.

  Displays all ecosystem resources across 7 tabs:
  Agents | Skills | MCP | Tools | Commands | Patterns | Learnings

  Each tab shows a searchable card grid with badge counts in tab headers.
  Clicking a card opens a detail drawer on the right.

  Subscribes to `"apm:library"` PubSub and refreshes every 30 seconds.
  """

  use ApmWeb, :live_view

  alias Apm.LibraryStore

  @refresh_interval 30_000

  @tabs ~w(agents skills mcp tools commands patterns learnings)a

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:library")
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end

    socket =
      socket
      |> assign(:page_title, "Library")
      |> assign(:active_nav, :library)
      |> assign(:tab, :agents)
      |> assign(:search_query, "")
      |> assign(:selected_item, nil)
      |> assign(:sidebar_collapsed, false)
      |> assign(:inspector_open, false)
      |> load_all_data()

    {:ok, socket |> ApmWeb.Components.SidebarNav.assign_sidebar_nav_data()}
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
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav current_path="/library" />
      </:sidebar>
      <:topbar>
        <.top_bar project_name="CCEM APM" />
      </:topbar>
      <:main>
        <div phx-window-keydown="keydown" style="display:flex;flex-direction:column;height:100%;overflow:hidden;">
          <%!-- Header --%>
          <div style="display:flex;align-items:center;justify-content:space-between;padding:0 1rem;height:3rem;border-bottom:1px solid var(--ccem-border);flex-shrink:0;">
            <div style="display:flex;align-items:center;gap:0.75rem;">
              <span style="font-size:0.875rem;font-weight:600;color:var(--ccem-text-primary);">CCEM Libraries</span>
              <.badge tone="neutral">{total_count(assigns)} resources</.badge>
            </div>
            <div style="display:flex;align-items:center;gap:0.5rem;">
              <.btn variant="ghost" size="xs" phx-click="refresh_library">Refresh</.btn>
              <span style="font-size:0.75rem;color:var(--ccem-text-muted);">Auto-refresh 30s</span>
            </div>
          </div>

          <%!-- Tab bar --%>
          <div style="border-bottom:1px solid var(--ccem-border);padding:0 1rem;display:flex;align-items:center;gap:0.25rem;overflow-x:auto;flex-shrink:0;">
            <%= for tab <- @tabs do %>
              <button
                phx-click="switch_tab"
                phx-value-tab={tab}
                style={"padding:0.5rem 0.75rem;font-size:0.75rem;font-weight:500;border-bottom:2px solid #{if @tab == tab, do: "var(--ccem-accent)", else: "transparent"};color:#{if @tab == tab, do: "var(--ccem-accent)", else: "var(--ccem-text-muted)"};background:none;cursor:pointer;white-space:nowrap;"}
              >
                {tab_label(tab)}
                <.badge tone={if @tab == tab, do: "accent", else: "neutral"} square={true} style="margin-left:0.25rem;">
                  {tab_count(assigns, tab)}
                </.badge>
              </button>
            <% end %>
          </div>

          <%!-- Search bar --%>
          <div style="padding:0.5rem 1rem;flex-shrink:0;background:var(--ccem-surface-subtle,var(--ccem-bg-secondary));">
            <.ds_input
              type="search"
              placeholder={"Search #{tab_label(@tab)}..."}
              value={@search_query}
              name="query"
              phx-change="search"
            />
          </div>

          <%!-- Content area --%>
          <div style="flex:1;display:flex;overflow:hidden;">
            <%!-- Card grid --%>
            <div style="flex:1;overflow-y:auto;padding:1rem;">
              <div :if={@filtered == []} style="text-align:center;padding:3rem 0;color:var(--ccem-text-muted);">
                <p style="font-size:1rem;">No {@tab} found</p>
                <p :if={@search_query != ""} style="font-size:0.875rem;margin-top:0.25rem;">Try adjusting your search</p>
              </div>

              <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:0.75rem;">
                <%= for {item, idx} <- Enum.with_index(@filtered) do %>
                  <.card padded={true}>
                    <div
                      phx-click="select_item"
                      phx-value-idx={idx}
                      style={"cursor:pointer;#{if @selected_item == item, do: "outline:2px solid var(--ccem-accent);border-radius:var(--ccem-radius,4px);", else: ""}"}
                    >
                      <div style="display:flex;align-items:flex-start;justify-content:space-between;gap:0.5rem;">
                        <span style="font-size:0.875rem;font-weight:600;color:var(--ccem-text-primary);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">
                          {display_name(item)}
                        </span>
                        {type_badge(assigns, item)}
                      </div>
                      <p style="font-size:0.75rem;color:var(--ccem-text-muted);margin-top:0.25rem;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;">
                        {item_description(item)}
                      </p>
                      <div style="display:flex;align-items:center;gap:0.5rem;margin-top:0.5rem;font-size:0.625rem;color:var(--ccem-text-faint,var(--ccem-text-muted));">
                        <span :if={item[:source]} style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:200px;">{item[:source]}</span>
                        <span :if={item[:last_modified]} style="white-space:nowrap;">{relative_time(item[:last_modified])}</span>
                      </div>
                    </div>
                  </.card>
                <% end %>
              </div>
            </div>

            <%!-- Detail drawer --%>
            <aside
              :if={@selected_item}
              style="width:24rem;border-left:1px solid var(--ccem-border);overflow-y:auto;flex-shrink:0;background:var(--ccem-surface,var(--ccem-bg-primary));"
            >
              <div style="padding:1rem;">
                <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:1rem;">
                  <span style="font-size:1rem;font-weight:700;color:var(--ccem-text-primary);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">
                    {display_name(@selected_item)}
                  </span>
                  <.btn variant="ghost" size="xs" phx-click="close_drawer">X</.btn>
                </div>

                {type_badge(assigns, @selected_item)}

                <div style="border-top:1px solid var(--ccem-border);margin:0.5rem 0;"></div>

                <%!-- Description --%>
                <div style="margin-bottom:1rem;">
                  <p style="font-size:0.75rem;font-weight:600;color:var(--ccem-text-muted);text-transform:uppercase;margin-bottom:0.25rem;">Description</p>
                  <p style="font-size:0.875rem;color:var(--ccem-text-secondary,var(--ccem-text-primary));">{item_description(@selected_item)}</p>
                </div>

                <%!-- Properties table --%>
                <div style="margin-bottom:1rem;">
                  <p style="font-size:0.75rem;font-weight:600;color:var(--ccem-text-muted);text-transform:uppercase;margin-bottom:0.25rem;">Properties</p>
                  <div style="background:var(--ccem-bg-secondary);border-radius:0.5rem;padding:0.75rem;">
                    <%= for {key, val} <- detail_properties(@selected_item) do %>
                      <div style="display:flex;align-items:flex-start;justify-content:space-between;gap:0.5rem;margin-bottom:0.5rem;">
                        <span style="font-size:0.75rem;color:var(--ccem-text-muted);white-space:nowrap;">{key}</span>
                        <span style="font-size:0.75rem;color:var(--ccem-text-primary);text-align:right;word-break:break-all;">{format_value(val)}</span>
                      </div>
                    <% end %>
                  </div>
                </div>

                <%!-- Triggers (skills only) --%>
                <div :if={@tab == :skills and (@selected_item[:triggers] || []) != []} style="margin-bottom:1rem;">
                  <p style="font-size:0.75rem;font-weight:600;color:var(--ccem-text-muted);text-transform:uppercase;margin-bottom:0.25rem;">Triggers</p>
                  <div style="display:flex;flex-direction:column;gap:0.25rem;">
                    <%= for trigger <- @selected_item[:triggers] || [] do %>
                      <div style="font-size:0.75rem;background:var(--ccem-bg-secondary);border-radius:0.25rem;padding:0.25rem 0.5rem;color:var(--ccem-text-secondary,var(--ccem-text-primary));">{trigger}</div>
                    <% end %>
                  </div>
                </div>

                <%!-- Related skills (patterns only) --%>
                <div :if={@tab == :patterns and (@selected_item[:related_skills] || []) != []} style="margin-bottom:1rem;">
                  <p style="font-size:0.75rem;font-weight:600;color:var(--ccem-text-muted);text-transform:uppercase;margin-bottom:0.25rem;">Related Skills</p>
                  <div style="display:flex;flex-wrap:wrap;gap:0.25rem;">
                    <%= for skill <- @selected_item[:related_skills] || [] do %>
                      <.badge tone="neutral">{skill}</.badge>
                    <% end %>
                  </div>
                </div>
              </div>
            </aside>
          </div>
        </div>
      </:main>
      <:inspector>
        <div style="padding:1rem;color:var(--ccem-text-muted);font-size:0.875rem;">
          <p>Select an item to inspect details.</p>
        </div>
      </:inspector>
    </.page_layout>
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
      <.badge tone={badge_tone(@badge_type)}>
        {@badge_type}
      </.badge>
      """
    else
      ~H""
    end
  end

  defp badge_tone(type) when is_binary(type) do
    cond do
      type in ~w(orchestrator persistent_service) -> "accent"
      type in ~w(squadron_lead quality_agent) -> "iris"
      type in ~w(swarm_agent cluster_agent) -> "info"
      type in ~w(agentlock security) -> "error"
      type in ~w(methodology architecture) -> "info"
      type in ~w(workflow documentation quality) -> "success"
      type in ~w(user project enabled) -> "warning"
      true -> "neutral"
    end
  end
  defp badge_tone(_), do: "neutral"

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
