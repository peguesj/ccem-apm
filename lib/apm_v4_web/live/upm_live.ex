defmodule ApmV4Web.UpmLive do
  @moduledoc """
  LiveView for the UPM (Unified Project Management) module.
  Provides project overview, PM/VCS integration management, work item tracking,
  drift detection, and bidirectional sync controls.

  Routes:
    /upm               - :index  project list + sync dashboard
    /upm/:project_id   - :project  project detail with integrations
    /upm/:project_id/board - :board  kanban board of work items
  """
  use ApmV4Web, :live_view

  alias ApmV4.UPM.{ProjectRegistry, PMIntegrationStore, VCSIntegrationStore, WorkItemStore, SyncEngine}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "upm:projects")
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "upm:pm_integrations")
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "upm:vcs_integrations")
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "upm:work_items")
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "upm:sync")
    end

    socket =
      socket
      |> assign(:page_title, "UPM")
      |> assign(:active_nav, :upm)
      |> assign(:active_skill_count, skill_count())
      |> assign(:flash_msg, nil)
      |> load_index_data()

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"project_id" => project_id}, _uri, socket) do
    live_action = socket.assigns.live_action

    socket =
      case ProjectRegistry.get_project(project_id) do
        {:ok, project} ->
          socket
          |> assign(:selected_project, project)
          |> load_project_data(project_id)

        {:error, :not_found} ->
          socket
          |> assign(:selected_project, nil)
          |> assign(:pm_integrations, [])
          |> assign(:vcs_integrations, [])
          |> assign(:work_items, [])
          |> assign(:drift_summary, nil)
          |> assign(:sync_history, [])
          |> assign(:flash_msg, "Project not found")
      end

    socket = assign(socket, :live_action, live_action)
    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :selected_project, nil)}
  end

  # Public API events

  @impl true
  def handle_event("scan_projects", _params, socket) do
    case ProjectRegistry.scan_and_sync() do
      {:ok, count} ->
        socket =
          socket
          |> assign(:flash_msg, "Scanned and synced #{count} projects")
          |> load_index_data()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :flash_msg, "Scan failed: #{inspect(reason)}")}
    end
  end

  def handle_event("sync_all", _params, socket) do
    projects = ProjectRegistry.list_projects()

    results =
      Enum.map(projects, fn project ->
        case SyncEngine.sync_project(project.id) do
          {:ok, result} -> %{project_id: project.id, ok: true, synced: result.synced_count}
          {:error, reason} -> %{project_id: project.id, ok: false, error: inspect(reason)}
        end
      end)

    total_synced = results |> Enum.filter(& &1.ok) |> Enum.map(& &1[:synced]) |> Enum.sum()
    failed = Enum.count(results, &(not &1.ok))

    msg =
      if failed > 0,
        do: "Synced #{total_synced} items (#{failed} projects failed)",
        else: "Synced #{total_synced} items across #{length(projects)} projects"

    {:noreply, socket |> assign(:flash_msg, msg) |> load_index_data()}
  end

  def handle_event("sync_project", %{"id" => project_id}, socket) do
    case SyncEngine.sync_project(project_id) do
      {:ok, result} ->
        msg = "Synced #{result.synced_count} items (#{result.drifted_count} drifted)"
        socket = socket |> assign(:flash_msg, msg) |> load_project_data(project_id)
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :flash_msg, "Sync failed: #{inspect(reason)}")}
    end
  end

  def handle_event("dismiss_flash", _params, socket) do
    {:noreply, assign(socket, :flash_msg, nil)}
  end

  # PubSub handlers

  @impl true
  def handle_info({:upm_project_updated, _project}, socket) do
    {:noreply, load_index_data(socket)}
  end

  def handle_info({:upm_pm_integration_updated, _integration}, socket) do
    project_id = get_in(socket.assigns, [:selected_project, :id])
    if project_id, do: {:noreply, load_project_data(socket, project_id)}, else: {:noreply, socket}
  end

  def handle_info({:upm_vcs_integration_updated, _integration}, socket) do
    project_id = get_in(socket.assigns, [:selected_project, :id])
    if project_id, do: {:noreply, load_project_data(socket, project_id)}, else: {:noreply, socket}
  end

  def handle_info({:upm_work_item_updated, _item}, socket) do
    project_id = get_in(socket.assigns, [:selected_project, :id])
    if project_id, do: {:noreply, load_project_data(socket, project_id)}, else: {:noreply, socket}
  end

  def handle_info({:upm_sync_complete, result}, socket) do
    socket =
      socket
      |> assign(:last_sync_result, result)
      |> load_index_data()

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Private helpers

  defp load_index_data(socket) do
    projects = ProjectRegistry.list_projects()
    drift_summary = WorkItemStore.detect_drift_all()
    sync_history = SyncEngine.get_history() |> Enum.take(5)

    socket
    |> assign(:projects, projects)
    |> assign(:project_count, length(projects))
    |> assign(:drift_summary, drift_summary)
    |> assign(:sync_history, sync_history)
    |> assign(:last_sync_result, nil)
  end

  defp load_project_data(socket, project_id) do
    pm_integrations = PMIntegrationStore.list_for_project(project_id)
    vcs_integrations = VCSIntegrationStore.list_for_project(project_id)
    work_items = WorkItemStore.list_for_project(project_id)
    sync_history = SyncEngine.get_history_for_project(project_id) |> Enum.take(10)

    socket
    |> assign(:pm_integrations, pm_integrations)
    |> assign(:vcs_integrations, vcs_integrations)
    |> assign(:work_items, work_items)
    |> assign(:sync_history, sync_history)
  end

  defp skill_count do
    try do
      case ApmV4.ProjectStore.get_tasks("_global") do
        tasks when is_list(tasks) -> Enum.count(tasks, &(Map.get(&1, "type") == "skill"))
        _ -> 0
      end
    rescue
      _ -> 0
    end
  end

  # ── Template ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-200 overflow-hidden">
      <!-- Sidebar nav -->
      <aside class="w-14 bg-base-100 border-r border-base-300 flex flex-col items-center py-3 gap-1 flex-shrink-0">
        <.nav_item icon="hero-squares-2x2" label="Dashboard" active={false} href="/" />
        <.nav_item icon="hero-globe-alt" label="All Projects" active={false} href="/apm-all" />
        <.nav_item icon="hero-rectangle-group" label="Formations" active={false} href="/formation" />
        <.nav_item icon="hero-circle-stack" label="UPM" active={true} href="/upm" />
        <.nav_item icon="hero-clock" label="Timeline" active={false} href="/timeline" />
        <.nav_item icon="hero-bell" label="Notifications" active={false} href="/notifications" />
        <.nav_item icon="hero-queue-list" label="Background Tasks" active={false} href="/tasks" />
        <.nav_item icon="hero-magnifying-glass" label="Project Scanner" active={false} href="/scanner" />
        <.nav_item icon="hero-bolt" label="Actions" active={false} href="/actions" />
        <.nav_item icon="hero-sparkles" label="Skills" active={false} href="/skills" badge={@active_skill_count} />
        <.nav_item icon="hero-arrow-path" label="Ralph" active={false} href="/ralph" />
        <.nav_item icon="hero-signal" label="Ports" active={false} href="/ports" />
        <.nav_item icon="hero-book-open" label="Docs" active={false} href="/docs" />
      </aside>

      <!-- Main content -->
      <main class="flex-1 overflow-y-auto">
        <!-- Header -->
        <div class="border-b border-base-300 bg-base-100 px-6 py-3 flex items-center justify-between">
          <div class="flex items-center gap-3">
            <.icon name="hero-circle-stack" class="size-5 text-primary" />
            <h1 class="font-semibold text-base-content">Unified Project Management</h1>
            <%= if @live_action == :project and @selected_project do %>
              <span class="text-base-content/40 mx-1">/</span>
              <span class="text-sm font-medium"><%= @selected_project.name %></span>
            <% end %>
            <%= if @live_action == :board and @selected_project do %>
              <span class="text-base-content/40 mx-1">/</span>
              <.link navigate={"/upm/#{@selected_project.id}"} class="text-sm text-primary hover:underline">
                <%= @selected_project.name %>
              </.link>
              <span class="text-base-content/40 mx-1">/</span>
              <span class="text-sm font-medium">Board</span>
            <% end %>
          </div>
          <div class="flex items-center gap-2">
            <%= if @live_action == :index do %>
              <button phx-click="scan_projects" class="btn btn-xs btn-outline">
                <.icon name="hero-magnifying-glass" class="size-3" /> Scan
              </button>
              <button phx-click="sync_all" class="btn btn-xs btn-primary">
                <.icon name="hero-arrow-path" class="size-3" /> Sync All
              </button>
            <% end %>
            <%= if @live_action in [:project, :board] and @selected_project do %>
              <.link navigate="/upm" class="btn btn-xs btn-ghost">
                <.icon name="hero-arrow-left" class="size-3" /> All Projects
              </.link>
              <button phx-click="sync_project" phx-value-id={@selected_project.id} class="btn btn-xs btn-primary">
                <.icon name="hero-arrow-path" class="size-3" /> Sync
              </button>
            <% end %>
          </div>
        </div>

        <!-- Flash message -->
        <%= if @flash_msg do %>
          <div class="mx-6 mt-4 alert alert-info text-sm py-2">
            <span><%= @flash_msg %></span>
            <button phx-click="dismiss_flash" class="btn btn-xs btn-ghost ml-auto">
              <.icon name="hero-x-mark" class="size-3" />
            </button>
          </div>
        <% end %>

        <!-- Content area -->
        <div class="p-6">
          <%= case @live_action do %>
            <% :index -> %>
              <.render_index {assigns} />
            <% :project -> %>
              <%= if @selected_project do %>
                <.render_project {assigns} />
              <% else %>
                <div class="alert alert-warning">Project not found.</div>
              <% end %>
            <% :board -> %>
              <%= if @selected_project do %>
                <.render_board {assigns} />
              <% else %>
                <div class="alert alert-warning">Project not found.</div>
              <% end %>
          <% end %>
        </div>
      </main>
    </div>
    """
  end

  # ── Sub-renders ─────────────────────────────────────────────────────────

  defp render_index(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Summary stats -->
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div class="stat bg-base-100 rounded-lg border border-base-300 py-3 px-4">
          <div class="stat-title text-xs">Projects</div>
          <div class="stat-value text-2xl"><%= @project_count %></div>
        </div>
        <div class="stat bg-base-100 rounded-lg border border-base-300 py-3 px-4">
          <div class="stat-title text-xs">Synced Items</div>
          <div class="stat-value text-2xl text-success"><%= Map.get(@drift_summary, :synced, 0) %></div>
        </div>
        <div class="stat bg-base-100 rounded-lg border border-base-300 py-3 px-4">
          <div class="stat-title text-xs">Drifted Items</div>
          <div class="stat-value text-2xl text-warning"><%= Map.get(@drift_summary, :drifted, 0) %></div>
        </div>
        <div class="stat bg-base-100 rounded-lg border border-base-300 py-3 px-4">
          <div class="stat-title text-xs">Recent Syncs</div>
          <div class="stat-value text-2xl"><%= length(@sync_history) %></div>
        </div>
      </div>

      <!-- Projects list -->
      <div class="bg-base-100 rounded-lg border border-base-300">
        <div class="px-4 py-3 border-b border-base-300 flex items-center justify-between">
          <h2 class="font-medium text-sm">Projects</h2>
          <span class="badge badge-outline badge-sm"><%= @project_count %></span>
        </div>
        <%= if @projects == [] do %>
          <div class="p-6 text-center text-base-content/40 text-sm">
            No projects found. Click <strong>Scan</strong> to discover projects.
          </div>
        <% else %>
          <div class="divide-y divide-base-300">
            <%= for project <- @projects do %>
              <div class="px-4 py-3 flex items-center justify-between hover:bg-base-200/50 transition-colors">
                <div class="flex items-center gap-3">
                  <.icon name="hero-folder" class="size-4 text-primary/70" />
                  <div>
                    <.link navigate={"/upm/#{project.id}"} class="font-medium text-sm hover:text-primary">
                      <%= project.name %>
                    </.link>
                    <div class="text-xs text-base-content/40 font-mono"><%= project.path %></div>
                  </div>
                </div>
                <div class="flex items-center gap-2">
                  <%= for tag <- Enum.take(project.stack || [], 3) do %>
                    <span class="badge badge-outline badge-xs"><%= tag %></span>
                  <% end %>
                  <.link navigate={"/upm/#{project.id}/board"} class="btn btn-xs btn-ghost">
                    Board
                  </.link>
                  <.link navigate={"/upm/#{project.id}"} class="btn btn-xs btn-outline">
                    View
                  </.link>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <!-- Recent sync history -->
      <%= if @sync_history != [] do %>
        <div class="bg-base-100 rounded-lg border border-base-300">
          <div class="px-4 py-3 border-b border-base-300">
            <h2 class="font-medium text-sm">Recent Sync Activity</h2>
          </div>
          <div class="divide-y divide-base-300">
            <%= for result <- @sync_history do %>
              <div class="px-4 py-2 flex items-center justify-between text-sm">
                <div class="flex items-center gap-2">
                  <.icon name="hero-arrow-path" class="size-3 text-base-content/40" />
                  <span class="font-mono text-xs text-base-content/60 truncate max-w-xs">
                    <%= result.project_id %>
                  </span>
                </div>
                <div class="flex items-center gap-4 text-xs text-base-content/60">
                  <span><%= result.synced_count %> synced</span>
                  <%= if result.drifted_count > 0 do %>
                    <span class="text-warning"><%= result.drifted_count %> drifted</span>
                  <% end %>
                  <%= if result.errors != [] do %>
                    <span class="text-error"><%= length(result.errors) %> errors</span>
                  <% end %>
                  <span><%= format_dt(result.completed_at) %></span>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_project(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Project info -->
      <div class="bg-base-100 rounded-lg border border-base-300 p-4">
        <div class="flex items-center justify-between mb-3">
          <div>
            <h2 class="font-semibold"><%= @selected_project.name %></h2>
            <div class="text-xs text-base-content/40 font-mono"><%= @selected_project.path %></div>
          </div>
          <div class="flex gap-2">
            <%= for tag <- @selected_project.stack || [] do %>
              <span class="badge badge-outline badge-sm"><%= tag %></span>
            <% end %>
          </div>
        </div>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-3 text-sm">
          <div class="text-base-content/60">VCS URL: <span class="text-base-content font-mono text-xs"><%= @selected_project.vcs_url || "—" %></span></div>
          <div class="text-base-content/60">Branch Strategy: <span class="text-base-content"><%= @selected_project.branch_strategy || "—" %></span></div>
          <div class="text-base-content/60">PM Integrations: <span class="text-base-content"><%= length(@pm_integrations) %></span></div>
          <div class="text-base-content/60">VCS Integrations: <span class="text-base-content"><%= length(@vcs_integrations) %></span></div>
        </div>
      </div>

      <div class="grid md:grid-cols-2 gap-6">
        <!-- PM Integrations -->
        <div class="bg-base-100 rounded-lg border border-base-300">
          <div class="px-4 py-3 border-b border-base-300 flex items-center justify-between">
            <h3 class="font-medium text-sm">PM Integrations</h3>
            <span class="badge badge-outline badge-sm"><%= length(@pm_integrations) %></span>
          </div>
          <%= if @pm_integrations == [] do %>
            <div class="p-4 text-center text-sm text-base-content/40">No PM integrations configured.</div>
          <% else %>
            <div class="divide-y divide-base-300">
              <%= for integration <- @pm_integrations do %>
                <div class="px-4 py-3">
                  <div class="flex items-center justify-between">
                    <div class="flex items-center gap-2">
                      <span class="badge badge-primary badge-sm capitalize"><%= integration.platform %></span>
                      <span class="text-sm text-base-content/70"><%= integration.workspace %></span>
                    </div>
                    <%= if integration.sync_enabled do %>
                      <span class="badge badge-success badge-xs">sync on</span>
                    <% else %>
                      <span class="badge badge-ghost badge-xs">sync off</span>
                    <% end %>
                  </div>
                  <div class="mt-1 text-xs text-base-content/40">
                    <%= integration.base_url %> · <%= integration.project_key %>
                    <%= if integration.last_sync_at do %>
                      · Synced <%= format_dt(integration.last_sync_at) %>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>

        <!-- VCS Integrations -->
        <div class="bg-base-100 rounded-lg border border-base-300">
          <div class="px-4 py-3 border-b border-base-300 flex items-center justify-between">
            <h3 class="font-medium text-sm">VCS Integrations</h3>
            <span class="badge badge-outline badge-sm"><%= length(@vcs_integrations) %></span>
          </div>
          <%= if @vcs_integrations == [] do %>
            <div class="p-4 text-center text-sm text-base-content/40">No VCS integrations configured.</div>
          <% else %>
            <div class="divide-y divide-base-300">
              <%= for integration <- @vcs_integrations do %>
                <div class="px-4 py-3">
                  <div class="flex items-center justify-between">
                    <div class="flex items-center gap-2">
                      <span class="badge badge-secondary badge-sm capitalize"><%= integration.provider %></span>
                      <span class="text-xs font-mono text-base-content/60 truncate max-w-xs"><%= integration.repo_url %></span>
                    </div>
                    <span class="badge badge-outline badge-xs capitalize"><%= integration.sync_type %></span>
                  </div>
                  <div class="mt-1 text-xs text-base-content/40">
                    default: <%= integration.default_branch %>
                    <%= if integration.last_sync_at do %>
                      · Synced <%= format_dt(integration.last_sync_at) %>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>

      <!-- Work items summary -->
      <div class="bg-base-100 rounded-lg border border-base-300">
        <div class="px-4 py-3 border-b border-base-300 flex items-center justify-between">
          <h3 class="font-medium text-sm">Work Items</h3>
          <div class="flex items-center gap-2">
            <span class="badge badge-outline badge-sm"><%= length(@work_items) %></span>
            <.link navigate={"/upm/#{@selected_project.id}/board"} class="btn btn-xs btn-outline">
              Kanban Board
            </.link>
          </div>
        </div>
        <%= if @work_items == [] do %>
          <div class="p-4 text-center text-sm text-base-content/40">
            No work items. Run a sync to pull items from PM platforms.
          </div>
        <% else %>
          <div class="p-3 grid grid-cols-5 gap-2">
            <%= for {status, label} <- [todo: "Todo", in_progress: "In Progress", done: "Done", cancelled: "Cancelled", backlog: "Backlog"] do %>
              <div class="text-center">
                <div class="text-xs text-base-content/60"><%= label %></div>
                <div class="text-lg font-semibold">
                  <%= Enum.count(@work_items, &(&1.status == status)) %>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <!-- Sync history -->
      <%= if @sync_history != [] do %>
        <div class="bg-base-100 rounded-lg border border-base-300">
          <div class="px-4 py-3 border-b border-base-300">
            <h3 class="font-medium text-sm">Sync History</h3>
          </div>
          <div class="divide-y divide-base-300">
            <%= for result <- @sync_history do %>
              <div class="px-4 py-2 flex items-center justify-between text-xs">
                <div class="flex items-center gap-3 text-base-content/60">
                  <span><%= result.synced_count %> synced</span>
                  <%= if result.drifted_count > 0 do %>
                    <span class="text-warning"><%= result.drifted_count %> drifted</span>
                  <% end %>
                  <%= if result.errors != [] do %>
                    <span class="text-error"><%= length(result.errors) %> errors</span>
                  <% end %>
                </div>
                <span class="text-base-content/40"><%= format_dt(result.started_at) %></span>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_board(assigns) do
    statuses = [:backlog, :todo, :in_progress, :done, :cancelled]
    status_labels = %{backlog: "Backlog", todo: "Todo", in_progress: "In Progress", done: "Done", cancelled: "Cancelled"}
    status_colors = %{backlog: "badge-ghost", todo: "badge-outline", in_progress: "badge-primary", done: "badge-success", cancelled: "badge-error"}

    assigns =
      assigns
      |> Map.put(:statuses, statuses)
      |> Map.put(:status_labels, status_labels)
      |> Map.put(:status_colors, status_colors)

    ~H"""
    <div class="flex gap-4 overflow-x-auto pb-4" style="min-height: 70vh;">
      <%= for status <- @statuses do %>
        <div class="flex-shrink-0 w-64">
          <div class="flex items-center gap-2 mb-3">
            <span class={"badge badge-sm #{Map.get(@status_colors, status, "badge-ghost")} capitalize"}>
              <%= Map.get(@status_labels, status, to_string(status)) %>
            </span>
            <span class="text-xs text-base-content/40">
              <%= Enum.count(@work_items, &(&1.status == status)) %>
            </span>
          </div>
          <div class="space-y-2">
            <%= for item <- Enum.filter(@work_items, &(&1.status == status)) do %>
              <div class="bg-base-100 border border-base-300 rounded-lg p-3 text-sm hover:border-primary/40 transition-colors">
                <div class="font-medium text-sm leading-tight mb-1"><%= item.title %></div>
                <div class="flex items-center justify-between mt-2">
                  <%= if item.platform_key do %>
                    <span class="badge badge-ghost badge-xs font-mono"><%= item.platform_key %></span>
                  <% end %>
                  <%= if item.priority do %>
                    <span class={"badge badge-xs #{priority_color(item.priority)}"}>
                      <%= item.priority %>
                    </span>
                  <% end %>
                </div>
                <%= if item.platform_url do %>
                  <div class="mt-2">
                    <a href={item.platform_url} target="_blank" class="text-xs text-primary hover:underline">
                      Open in PM platform
                    </a>
                  </div>
                <% end %>
                <%= if item.sync_status == :drift do %>
                  <div class="mt-1 badge badge-warning badge-xs">drift detected</div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Nav component ─────────────────────────────────────────────────────────

  defp nav_item(assigns) do
    assigns = assign_new(assigns, :badge, fn -> nil end)

    ~H"""
    <a
      href={@href}
      title={@label}
      class={[
        "relative flex items-center justify-center w-10 h-10 rounded-lg transition-colors text-base-content/60 hover:bg-base-200 hover:text-base-content",
        @active && "bg-primary/10 text-primary"
      ]}
    >
      <.icon name={@icon} class="size-5" />
      <%= if @badge && @badge > 0 do %>
        <span class="absolute -top-0.5 -right-0.5 badge badge-primary badge-xs text-[9px] min-w-[14px] h-[14px] px-0.5">
          <%= @badge %>
        </span>
      <% end %>
    </a>
    """
  end

  # ── Format helpers ────────────────────────────────────────────────────────

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end
  defp format_dt(_), do: "—"

  defp priority_color(:urgent), do: "badge-error"
  defp priority_color(:high), do: "badge-warning"
  defp priority_color(:medium), do: "badge-info"
  defp priority_color(:low), do: "badge-ghost"
  defp priority_color(_), do: "badge-ghost"
end
