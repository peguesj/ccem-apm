defmodule ApmV5Web.NotificationLive do
  @moduledoc """
  Dedicated notification panel LiveView with tabbed categories and richer cards.
  Tabs: All | Agents | Formations | Skills | Ship
  """

  use ApmV5Web, :live_view

  alias ApmV5.AgentRegistry

  @tab_categories %{
    "all" => nil,
    "agents" => ["agent", "deploy_agents"],
    "formations" => ["formation", "squadron", "swarm"],
    "skills" => ["skill", "upm", "ralph"],
    "ship" => ["ship"]
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:notifications")
      # US-019: EventBus subscription for AG-UI notification events
      ApmV5.AgUi.EventBus.subscribe("special:custom")
    end

    notifications = load_notifications()

    socket =
      socket
      |> assign(:page_title, "Notifications")
      |> assign(:notifications, notifications)
      |> assign(:active_tab, "all")
      |> assign(:tab_counts, compute_tab_counts(notifications))
      |> assign(:expanded_ids, MapSet.new())
      |> assign(:hide_showcase, true)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <.sidebar_nav current_path="/notifications" notification_count={@tab_counts["all"]} />

      <%!-- Main --%>
      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Header --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0">
          <h2 class="text-sm font-semibold">Notifications</h2>
          <div class="flex items-center gap-2">
            <label class="flex items-center gap-1.5 text-xs text-base-content/50 cursor-pointer">
              <input
                type="checkbox"
                class="checkbox checkbox-xs"
                phx-click="toggle_showcase_filter"
                checked={@hide_showcase}
              />
              Hide showcase
            </label>
            <button phx-click="dismiss_category" phx-value-category={@active_tab} class="btn btn-ghost btn-xs text-base-content/60" :if={@active_tab != "all"}>
              Dismiss category
            </button>
            <button phx-click="mark_all_read" class="btn btn-ghost btn-xs text-base-content/60">
              Mark all read
            </button>
          </div>
        </header>

        <%!-- Tabs --%>
        <div class="flex border-b border-base-300 bg-base-200 px-4 flex-shrink-0">
          <.tab_btn label="All" tab="all" active={@active_tab} count={@tab_counts["all"]} />
          <.tab_btn label="Agents" tab="agents" active={@active_tab} count={@tab_counts["agents"]} />
          <.tab_btn label="Formations" tab="formations" active={@active_tab} count={@tab_counts["formations"]} />
          <.tab_btn label="Skills" tab="skills" active={@active_tab} count={@tab_counts["skills"]} />
          <.tab_btn label="Ship" tab="ship" active={@active_tab} count={@tab_counts["ship"]} />
        </div>

        <%!-- Notification list --%>
        <div class="flex-1 overflow-y-auto p-4 space-y-2">
          <div :if={visible_notifications(@notifications, @active_tab, @hide_showcase) == []} class="text-center text-base-content/30 py-16 text-sm">
            No notifications in this category
          </div>
          <.notif_card
            :for={notif <- visible_notifications(@notifications, @active_tab, @hide_showcase)}
            notif={notif}
            expanded={MapSet.member?(@expanded_ids, notif.id)}
          />
        </div>
      </div>
    </div>
    """
  end

  # --- Tab button component ---
  attr :label, :string, required: true
  attr :tab, :string, required: true
  attr :active, :string, required: true
  attr :count, :integer, default: 0

  defp tab_btn(assigns) do
    ~H"""
    <button
      phx-click="set_tab"
      phx-value-tab={@tab}
      class={[
        "px-4 py-2 text-xs font-medium border-b-2 transition-colors flex items-center gap-1.5",
        @tab == @active && "border-primary text-primary",
        @tab != @active && "border-transparent text-base-content/50 hover:text-base-content"
      ]}
    >
      {@label}
      <span :if={@count > 0} class="badge badge-xs badge-error">{@count}</span>
    </button>
    """
  end

  # --- Notification card component ---
  attr :notif, :map, required: true
  attr :expanded, :boolean, default: false

  defp notif_card(assigns) do
    ~H"""
    <div class={[
      "bg-base-200 rounded-lg border transition-all",
      @notif.read && "border-base-300 opacity-60",
      !@notif.read && "border-primary/20"
    ]}>
      <div class="flex items-start gap-3 p-3">
        <%!-- Type icon --%>
        <div class={["mt-0.5 flex-shrink-0", type_icon_color(@notif.type)]}>
          <.icon name={type_icon(@notif.type)} class="size-4" />
        </div>

        <%!-- Content --%>
        <div class="flex-1 min-w-0">
          <div class="flex items-start justify-between gap-2">
            <p class="text-sm font-medium text-base-content truncate">{@notif.title}</p>
            <div class="flex items-center gap-1.5 flex-shrink-0">
              <span :if={@notif[:dupe_count] && @notif[:dupe_count] > 1} class="badge badge-xs badge-warning font-mono">
                x{@notif.dupe_count}
              </span>
              <span class="text-[10px] text-base-content/40 font-mono">
                {relative_time(@notif.timestamp)}
              </span>
            </div>
          </div>
          <p :if={@notif.message && @notif.message != ""} class="text-xs text-base-content/60 mt-0.5 line-clamp-2">
            {format_message(@notif.message)}
          </p>
          <%!-- Category chip --%>
          <div class="flex items-center gap-2 mt-1.5 flex-wrap">
            <span :if={@notif.category} class={["badge badge-xs font-mono", category_badge_class(@notif.category)]}>
              {@notif.category}
            </span>
            <span :if={@notif[:formation_id]} class="badge badge-xs badge-outline badge-primary font-mono text-[9px]">
              {@notif.formation_id}
            </span>
            <span :if={@notif[:agent_id]} class="badge badge-xs badge-outline badge-info font-mono text-[9px]">
              {@notif.agent_id}
            </span>
          </div>
          <%!-- Action buttons --%>
          <div class="flex items-center gap-2 mt-2">
            <a
              :if={@notif[:action_url]}
              href={@notif.action_url}
              class="btn btn-xs btn-ghost text-primary"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-3" /> View
            </a>
            <a
              :if={@notif.category == "ship" && @notif[:pr_url]}
              href={@notif.pr_url}
              target="_blank"
              rel="noopener noreferrer"
              class="btn btn-xs btn-ghost text-success"
            >
              <.icon name="hero-code-bracket" class="size-3" /> Open PR
            </a>
            <button
              :if={has_metadata?(@notif)}
              phx-click="toggle_expand"
              phx-value-id={@notif.id}
              class="btn btn-xs btn-ghost text-base-content/40 ml-auto"
            >
              <.icon name={if @expanded, do: "hero-chevron-up", else: "hero-chevron-down"} class="size-3" />
              {if @expanded, do: "Less", else: "More"}
            </button>
          </div>
          <%!-- Expanded metadata --%>
          <div :if={@expanded && has_metadata?(@notif)} class="mt-2 pt-2 border-t border-base-300 space-y-1">
            <.meta_row :if={@notif[:wave_number]} label="Wave" value={"#{@notif[:wave_number]} / #{@notif[:wave_total]}"} />
            <.meta_row :if={@notif[:story_id]} label="Story" value={@notif[:story_id]} />
            <.meta_row :if={@notif[:squadron_id]} label="Squadron" value={@notif[:squadron_id]} />
            <.meta_row :if={@notif[:namespace]} label="Namespace" value={@notif[:namespace]} />
            <.meta_row :if={@notif[:project_name]} label="Project" value={@notif[:project_name]} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp meta_row(assigns) do
    ~H"""
    <div class="flex items-center gap-2 text-xs">
      <span class="text-base-content/40 w-20 flex-shrink-0">{@label}</span>
      <span class="font-mono text-base-content/70">{@value}</span>
    </div>
    """
  end

  # --- Events ---

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("toggle_expand", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    expanded = socket.assigns.expanded_ids
    new_expanded =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)
    {:noreply, assign(socket, :expanded_ids, new_expanded)}
  end

  def handle_event("toggle_showcase_filter", _params, socket) do
    {:noreply, assign(socket, :hide_showcase, !socket.assigns.hide_showcase)}
  end

  def handle_event("dismiss_category", %{"category" => cat}, socket) do
    cats = @tab_categories[cat] || []
    if cats != [] do
      Enum.each(socket.assigns.notifications, fn n ->
        if to_string(n[:category]) in cats, do: AgentRegistry.mark_read(n.id)
      end)
    end
    notifications = load_notifications()
    {:noreply, socket
     |> assign(:notifications, notifications)
     |> assign(:tab_counts, compute_tab_counts(notifications))}
  end

  def handle_event("mark_all_read", _params, socket) do
    AgentRegistry.mark_all_read()
    notifications = load_notifications()
    {:noreply, socket
     |> assign(:notifications, notifications)
     |> assign(:tab_counts, compute_tab_counts(notifications))}
  end

  # --- PubSub ---

  @impl true
  def handle_info({:notification_added, _notif}, socket) do
    notifications = load_notifications()
    {:noreply, socket
     |> assign(:notifications, notifications)
     |> assign(:tab_counts, compute_tab_counts(notifications))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp load_notifications do
    AgentRegistry.get_notifications()
    |> Enum.sort_by(& &1.id, :desc)
  end

  defp visible_notifications(notifications, tab, hide_showcase) do
    notifications
    |> filtered_notifications(tab)
    |> maybe_hide_showcase(hide_showcase)
    |> dedup_notifications()
  end

  defp filtered_notifications(notifications, "all"), do: notifications
  defp filtered_notifications(notifications, tab) do
    cats = @tab_categories[tab] || []
    Enum.filter(notifications, fn n ->
      to_string(n[:category]) in cats
    end)
  end

  defp maybe_hide_showcase(notifications, false), do: notifications
  defp maybe_hide_showcase(notifications, true) do
    Enum.reject(notifications, fn n ->
      cat = to_string(n[:category])
      title = to_string(n[:title]) |> String.downcase()
      cat == "showcase" or String.contains?(title, "showcase")
    end)
  end

  defp dedup_notifications(notifications) do
    # Group by title+type+category, keep the most recent, add dupe count
    notifications
    |> Enum.group_by(fn n -> {n[:title], n[:type], n[:category]} end)
    |> Enum.map(fn {_key, group} ->
      most_recent = hd(group)
      count = length(group)
      if count > 1 do
        Map.put(most_recent, :dupe_count, count)
      else
        most_recent
      end
    end)
    |> Enum.sort_by(& &1.id, :desc)
  end

  defp compute_tab_counts(notifications) do
    %{
      "all" => Enum.count(notifications, &(!&1.read)),
      "agents" => count_unread(notifications, ["agent", "deploy_agents"]),
      "formations" => count_unread(notifications, ["formation", "squadron", "swarm"]),
      "skills" => count_unread(notifications, ["skill", "upm", "ralph"]),
      "ship" => count_unread(notifications, ["ship"])
    }
  end

  defp count_unread(notifications, cats) do
    Enum.count(notifications, fn n ->
      !n.read && to_string(n[:category]) in cats
    end)
  end

  defp type_icon("success"), do: "hero-check-circle"
  defp type_icon("warning"), do: "hero-exclamation-triangle"
  defp type_icon("error"), do: "hero-x-circle"
  defp type_icon(_), do: "hero-information-circle"

  defp type_icon_color("success"), do: "text-success"
  defp type_icon_color("warning"), do: "text-warning"
  defp type_icon_color("error"), do: "text-error"
  defp type_icon_color(_), do: "text-info"

  defp has_metadata?(notif) do
    notif[:wave_number] || notif[:story_id] || notif[:squadron_id] ||
    notif[:namespace] || notif[:project_name] || notif[:action_url] || notif[:pr_url]
  end

  defp format_message(msg) when is_binary(msg) do
    trimmed = String.trim(msg)

    if String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") do
      case Jason.decode(trimmed) do
        {:ok, decoded} when is_map(decoded) ->
          decoded
          |> Enum.map(fn {k, v} -> "#{k}: #{inspect(v)}" end)
          |> Enum.join(" | ")

        {:ok, decoded} when is_list(decoded) ->
          Enum.map_join(decoded, ", ", &to_string/1)

        _ ->
          msg
      end
    else
      msg
    end
  end

  defp format_message(msg), do: to_string(msg)

  defp category_badge_class("agent"), do: "badge-success badge-outline"
  defp category_badge_class("deploy_agents"), do: "badge-success badge-outline"
  defp category_badge_class("formation"), do: "badge-accent badge-outline"
  defp category_badge_class("squadron"), do: "badge-info badge-outline"
  defp category_badge_class("swarm"), do: "badge-warning badge-outline"
  defp category_badge_class("skill"), do: "badge-secondary badge-outline"
  defp category_badge_class("upm"), do: "badge-primary badge-outline"
  defp category_badge_class("ralph"), do: "badge-primary badge-outline"
  defp category_badge_class("ship"), do: "badge-info badge-outline"
  defp category_badge_class("showcase"), do: "badge-ghost"
  defp category_badge_class(_), do: "badge-ghost"

  defp relative_time(nil), do: ""
  defp relative_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)
        cond do
          diff < 60 -> "#{diff}s ago"
          diff < 3600 -> "#{div(diff, 60)}m ago"
          diff < 86400 -> "#{div(diff, 3600)}h ago"
          true -> "#{div(diff, 86400)}d ago"
        end
      _ -> ts
    end
  end
  defp relative_time(_), do: ""
end
