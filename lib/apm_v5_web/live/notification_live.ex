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
      |> assign(:expanded_formations, MapSet.new())
      |> assign(:expanded_upm, MapSet.new())
      |> assign(:pending_decisions, %{})
      |> assign(:lazy_context, %{})
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
            formation_expanded={MapSet.member?(@expanded_formations, notif.id)}
            upm_expanded={MapSet.member?(@expanded_upm, notif.id)}
            pending_decision={Map.get(@pending_decisions, notif.id)}
            lazy_context={Map.get(@lazy_context, notif.id)}
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
  attr :formation_expanded, :boolean, default: false
  attr :upm_expanded, :boolean, default: false
  attr :pending_decision, :any, default: nil
  attr :lazy_context, :any, default: nil

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
          <div class="flex items-center gap-2 mt-2 flex-wrap">
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
            <%!-- UPM contextual action buttons --%>
            <div
              :if={@notif[:category] in ["upm"] || @notif[:upm_context] != nil}
              class="flex items-center gap-1 flex-wrap"
            >
              <.link
                :if={@notif[:story_id]}
                navigate="/upm"
                class="btn btn-xs btn-ghost text-primary"
              >
                <.icon name="hero-document-text" class="size-3" />
                Story {@notif[:story_id]}
              </.link>
              <.link
                :if={@notif[:wave_number]}
                navigate="/upm"
                class="btn btn-xs btn-ghost text-primary"
              >
                <.icon name="hero-queue-list" class="size-3" />
                Wave {@notif[:wave_number]}{if @notif[:wave_total], do: "/#{@notif[:wave_total]}", else: ""}
              </.link>
              <.link navigate="/upm" class="btn btn-xs btn-ghost text-primary">
                <.icon name="hero-book-open" class="size-3" /> View PRD
              </.link>
            </div>
            <%!-- Ralph contextual action buttons --%>
            <div
              :if={@notif[:category] == "ralph" || String.contains?(to_string(@notif[:title]), "Ralph")}
              class="flex items-center gap-1 flex-wrap"
            >
              <.link navigate="/ralph" class="btn btn-xs btn-ghost text-warning">
                <.icon name="hero-chart-bar" class="size-3" /> View Flowchart
              </.link>
              <span
                :if={@notif[:story_id]}
                class="badge badge-xs badge-warning badge-outline font-mono"
              >
                Story {@notif[:story_id]}
              </span>
              <span
                :if={@notif[:event_type] && String.contains?(to_string(@notif[:event_type]), "complete")}
                class="badge badge-xs badge-success font-mono"
              >
                Done
              </span>
            </div>
            <%!-- Formation contextual action buttons --%>
            <div
              :if={@notif[:category] in ["formation", "squadron", "swarm"]}
              class="flex items-center gap-1 flex-wrap"
            >
              <.link
                :if={@notif[:formation_id]}
                navigate={"/formation?id=#{@notif[:formation_id]}"}
                class="btn btn-xs btn-ghost text-accent"
              >
                <.icon name="hero-rectangle-group" class="size-3" /> Formation →
              </.link>
              <span
                :if={@notif[:wave_number]}
                class="badge badge-xs badge-accent badge-outline font-mono"
              >
                Wave {@notif[:wave_number]}
              </span>
              <.link
                :if={@notif[:agent_id]}
                navigate="/agents"
                class="btn btn-xs btn-ghost text-info"
              >
                <.icon name="hero-cpu-chip" class="size-3" /> Agents →
              </.link>
            </div>
            <%!-- Skill contextual action button --%>
            <.link
              :if={@notif[:category] == "skill"}
              navigate="/skills"
              class="btn btn-xs btn-ghost text-secondary"
            >
              <.icon name="hero-sparkles" class="size-3" /> Skills →
            </.link>
            <%!-- Decision Gate buttons — pending_approval type or decision category --%>
            <div
              :if={@notif[:type] == "pending_approval" || @notif[:category] == "decision"}
              class="flex items-center gap-1"
            >
              <button
                :if={@pending_decision == nil}
                phx-click="approve_action"
                phx-value-id={@notif.id}
                class="btn btn-xs btn-success"
              >
                <.icon name="hero-check" class="size-3" /> Approve
              </button>
              <button
                :if={@pending_decision == nil}
                phx-click="reject_action"
                phx-value-id={@notif.id}
                class="btn btn-xs btn-error btn-outline"
              >
                <.icon name="hero-x-mark" class="size-3" /> Reject
              </button>
              <span :if={@pending_decision == :approved} class="badge badge-xs badge-success font-mono">approved</span>
              <span :if={@pending_decision == :rejected} class="badge badge-xs badge-error font-mono">rejected</span>
            </div>
            <%!-- Formation tree toggle --%>
            <button
              :if={@notif[:category] in ["formation", "squadron", "swarm"]}
              phx-click="toggle_formation_panel"
              phx-value-id={@notif.id}
              class="btn btn-xs btn-ghost text-accent"
            >
              <.icon name={if @formation_expanded, do: "hero-chevron-up", else: "hero-chevron-right"} class="size-3" />
              {if @formation_expanded, do: "Hide Formation", else: "Show Formation"}
            </button>
            <%!-- UPM story progress toggle --%>
            <button
              :if={@notif[:category] in ["upm"] || @notif[:upm_context] != nil}
              phx-click="toggle_upm_panel"
              phx-value-id={@notif.id}
              class="btn btn-xs btn-ghost text-primary"
            >
              <.icon name={if @upm_expanded, do: "hero-chevron-up", else: "hero-chevron-right"} class="size-3" />
              {if @upm_expanded, do: "Hide Story Progress", else: "Show Story Progress"}
            </button>
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
          <%!-- Formation tree panel --%>
          <div :if={@formation_expanded} class="mt-2 pt-2 border-t border-accent/20">
            <p class="text-xs font-semibold text-accent mb-1.5">Formation Hierarchy</p>
            <div :if={@lazy_context == nil} class="text-xs text-base-content/40 italic">
              Loading...
              <span phx-hook="LoadContext" id={"ctx-#{@notif.id}"} phx-value-id={@notif.id} phx-value-type="formation" style="display:none" />
            </div>
            <div :if={@lazy_context != nil} class="font-mono text-xs">
              <%!-- Session row --%>
              <div :if={@lazy_context[:session_id]} class="flex items-center gap-1.5 text-base-content/50">
                <span class="text-base-content/30">├─</span>
                <.icon name="hero-circle-stack" class="size-3 text-base-content/40" />
                <span class="text-base-content/50">session:</span>
                <span class="text-base-content/60">{@lazy_context[:session_id]}</span>
              </div>
              <%!-- Formation row --%>
              <div :if={@lazy_context[:formation_id]} class="flex items-center gap-1.5 pl-3 text-accent">
                <span class="text-base-content/30">├─</span>
                <.icon name="hero-rectangle-group" class="size-3 text-accent" />
                <span class="text-accent/70">formation:</span>
                <span class="text-accent font-semibold">{@lazy_context[:formation_id]}</span>
              </div>
              <%!-- Squadron rows --%>
              <div :if={@lazy_context[:squadrons] && @lazy_context[:squadrons] != []} class="pl-6 space-y-0.5">
                <div :for={sq <- @lazy_context[:squadrons]} class="flex items-center gap-1.5 text-info">
                  <span class="text-base-content/30">├─</span>
                  <.icon name="hero-user-group" class="size-3 text-info" />
                  <span class="text-info/70">squadron:</span>
                  <span class="text-info">{sq}</span>
                </div>
              </div>
              <%!-- Swarm rows --%>
              <div :if={@lazy_context[:swarms] && @lazy_context[:swarms] != []} class="pl-9 space-y-0.5">
                <div :for={sw <- @lazy_context[:swarms]} class="flex items-center gap-1.5 text-warning">
                  <span class="text-base-content/30">├─</span>
                  <.icon name="hero-squares-plus" class="size-3 text-warning" />
                  <span class="text-warning/70">swarm:</span>
                  <span class="text-warning">{sw}</span>
                </div>
              </div>
              <%!-- Agent rows --%>
              <div :if={@lazy_context[:agents] && @lazy_context[:agents] != []} class="pl-12 space-y-0.5">
                <div :for={ag <- @lazy_context[:agents]} class="flex items-center gap-1.5 text-base-content/60">
                  <span class="text-base-content/30">└─</span>
                  <.icon name="hero-cpu-chip" class="size-3 text-base-content/50" />
                  <span class="text-base-content/40">agent:</span>
                  <span class="text-base-content/70">{ag}</span>
                </div>
              </div>
              <%!-- Empty state --%>
              <div :if={@lazy_context == %{} || (@lazy_context[:formation_id] == nil && @lazy_context[:squadrons] == [] && @lazy_context[:agents] == [])} class="text-base-content/30 italic">
                No hierarchy data available
              </div>
            </div>
          </div>
          <%!-- UPM story progress panel --%>
          <div :if={@upm_expanded} class="mt-2 pt-2 border-t border-primary/20">
            <p class="text-xs font-semibold text-primary mb-1.5">Story Progress</p>
            <div :if={@lazy_context == nil} class="text-xs text-base-content/40 italic">
              Loading...
              <span phx-hook="LoadContext" id={"ctx-upm-#{@notif.id}"} phx-value-id={@notif.id} phx-value-type="upm" style="display:none" />
            </div>
            <div :if={@lazy_context != nil} class="space-y-1 font-mono text-xs text-base-content/70">
              <.meta_row :if={@lazy_context[:story_id]} label="Story" value={to_string(@lazy_context[:story_id])} />
              <.meta_row :if={@lazy_context[:story_title]} label="Title" value={to_string(@lazy_context[:story_title])} />
              <.meta_row :if={@lazy_context[:feature_name]} label="Feature" value={to_string(@lazy_context[:feature_name])} />
              <.meta_row :if={@lazy_context[:status]} label="Status" value={to_string(@lazy_context[:status])} />
              <.meta_row :if={@lazy_context[:wave]} label="Wave" value={to_string(@lazy_context[:wave])} />
              <.meta_row :if={@lazy_context[:project_name]} label="Project" value={to_string(@lazy_context[:project_name])} />
              <.meta_row :if={@lazy_context[:upm_session_id]} label="Session" value={to_string(@lazy_context[:upm_session_id])} />
              <div :if={@lazy_context[:story_id] == nil && @lazy_context[:feature_name] == nil} class="text-base-content/30 italic">
                No story data available — ensure upm_context is included in POST /api/notify payload
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    <.wizard page="notifications" />
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

  def handle_event("approve_action", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:decisions", {:decision, id, :approved})
    pending = Map.put(socket.assigns.pending_decisions, id, :approved)
    {:noreply, assign(socket, :pending_decisions, pending)}
  end

  def handle_event("reject_action", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:decisions", {:decision, id, :rejected})
    pending = Map.put(socket.assigns.pending_decisions, id, :rejected)
    {:noreply, assign(socket, :pending_decisions, pending)}
  end

  def handle_event("toggle_formation_panel", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    expanded = socket.assigns.expanded_formations
    new_expanded =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)
    {:noreply, assign(socket, :expanded_formations, new_expanded)}
  end

  def handle_event("toggle_upm_panel", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    expanded = socket.assigns.expanded_upm
    new_expanded =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)
    {:noreply, assign(socket, :expanded_upm, new_expanded)}
  end

  def handle_event("load_context", %{"id" => id_str, "type" => type}, socket) do
    id = String.to_integer(id_str)
    context = lazy_load_context(id, type, socket.assigns.notifications)
    lazy = Map.put(socket.assigns.lazy_context, id, context)
    {:noreply, assign(socket, :lazy_context, lazy)}
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

  # Lazy-loads context data for a notification panel.
  # Pulls what it can from the notification itself; falls back to AgentRegistry
  # for formation hierarchy or UPM story data.
  defp lazy_load_context(id, "formation", notifications) do
    notif = Enum.find(notifications, fn n -> n.id == id end)
    formation_id = notif[:formation_id]

    {session_id, squadrons, swarms, agents} =
      if formation_id do
        members = AgentRegistry.list_formation(formation_id)
        session =
          members
          |> Enum.map(& &1[:session_id])
          |> Enum.reject(&is_nil/1)
          |> List.first()
        sq_list =
          members
          |> Enum.map(& &1[:squadron])
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
        sw_list =
          members
          |> Enum.map(& &1[:swarm_id])
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
        ag_list =
          members
          |> Enum.map(& &1[:agent_id])
          |> Enum.reject(&is_nil/1)
        {session, sq_list, sw_list, ag_list}
      else
        session = notif[:session_id]
        fallback_sq = if notif[:squadron_id], do: [notif[:squadron_id]], else: []
        fallback_sw = if notif[:swarm_id], do: [notif[:swarm_id]], else: []
        fallback_ag = if notif[:agent_id], do: [notif[:agent_id]], else: []
        {session, fallback_sq, fallback_sw, fallback_ag}
      end

    %{
      session_id: session_id,
      formation_id: formation_id,
      squadrons: squadrons,
      swarms: swarms,
      agents: agents
    }
  end

  defp lazy_load_context(id, "upm", notifications) do
    notif = Enum.find(notifications, fn n -> n.id == id end)
    upm_ctx = notif[:upm_context] || %{}

    # upm_context may have string keys (decoded JSON) or atom keys
    get_ctx = fn keys -> Enum.find_value(keys, fn k -> upm_ctx[k] end) end

    %{
      story_id: get_ctx.([:story_id, "story_id"]) || notif[:story_id],
      story_title: get_ctx.([:story_title, "story_title"]),
      status: get_ctx.([:status, "status"]),
      wave: get_ctx.([:wave, "wave", :wave_number, "wave_number"]) || notif[:wave_number],
      project_name: get_ctx.([:project_name, "project_name"]) || notif[:project_name],
      feature_name: get_ctx.([:feature_name, "feature_name"]),
      upm_session_id: get_ctx.([:upm_session_id, "upm_session_id"])
    }
  end

  defp lazy_load_context(_id, _type, _notifications), do: %{}
end
