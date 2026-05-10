defmodule ApmV5Web.ActionsLive do
  @moduledoc """
  LiveView for the Action Engine dashboard at /actions.

  Displays the action catalog, recent run history, and provides a
  modal to trigger actions against registered projects.
  """

  use ApmV5Web, :live_view


  alias ApmV5.ActionEngine
  alias ApmV5.ProjectScanner

  @refresh_interval 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
      # US-021: EventBus subscription for AG-UI activity events
      ApmV5.AgUi.EventBus.subscribe("activity:*")
    end

    catalog = safe_call(fn -> ActionEngine.list_catalog() end, [])
    runs = safe_call(fn -> ActionEngine.list_runs() end, [])
    projects = load_projects()

    {:ok,
     socket
     |> assign(:page_title, "Actions")
     |> assign(:catalog, catalog)
     |> assign(:runs, runs)
     |> assign(:projects, projects)
     |> assign(:show_modal, false)
     |> assign(:selected_action, nil)
     |> assign(:project_path, "")
     |> assign(:selected_project, nil)
     |> assign(:selected_run, nil)
     |> assign(:scanning, false)
     |> assign(:sidebar_collapsed, false)
     |> assign(:inspector_open, false)
     |> assign(:selected_paths, MapSet.new())
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    runs = safe_call(fn -> ActionEngine.list_runs() end, socket.assigns.runs)
    projects = load_projects()
    {:noreply, socket |> assign(:runs, runs) |> assign(:projects, projects)}
  end

  def handle_info(:scan_complete, socket) do
    projects = load_projects()
    {:noreply, socket |> assign(:scanning, false) |> assign(:projects, projects)}
  end

  @impl true
  def handle_event("open_run_modal", %{"action" => action_id} = params, socket) do
    action = Enum.find(socket.assigns.catalog, &(&1.id == action_id))
    path = Map.get(params, "path", "")
    project = if path != "", do: Enum.find(socket.assigns.projects, &(&1.path == path)), else: nil

    {:noreply,
     socket
     |> assign(:show_modal, true)
     |> assign(:selected_action, action)
     |> assign(:project_path, path)
     |> assign(:selected_project, project)}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, false)
     |> assign(:selected_action, nil)
     |> assign(:selected_run, nil)
     |> assign(:selected_project, nil)}
  end

  def handle_event("update_path", %{"project_path" => path}, socket) do
    project = Enum.find(socket.assigns.projects, &(&1.path == path))
    {:noreply, socket |> assign(:project_path, path) |> assign(:selected_project, project)}
  end

  def handle_event("select_project", %{"path" => path}, socket) do
    project = Enum.find(socket.assigns.projects, &(&1.path == path))
    {:noreply, socket |> assign(:project_path, path) |> assign(:selected_project, project)}
  end

  def handle_event("run_action", %{"project_path" => path}, socket) do
    action = socket.assigns.selected_action

    result =
      safe_call(
        fn -> ActionEngine.run_action(action.id, path) end,
        {:error, "ActionEngine offline"}
      )

    case result do
      {:ok, _run_id} ->
        runs = safe_call(fn -> ActionEngine.list_runs() end, socket.assigns.runs)
        projects = load_projects()

        {:noreply,
         socket
         |> assign(:show_modal, false)
         |> assign(:selected_action, nil)
         |> assign(:selected_project, nil)
         |> assign(:runs, runs)
         |> assign(:projects, projects)
         |> put_flash(:info, "Action started: #{action.name}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{reason}")}
    end
  end

  def handle_event("view_result", %{"id" => run_id}, socket) do
    run =
      safe_call(
        fn ->
          case ActionEngine.get_run(run_id) do
            {:ok, r} -> r
            _ -> nil
          end
        end,
        nil
      )

    {:noreply, assign(socket, :selected_run, run)}
  end

  def handle_event("scan_projects", _params, socket) do
    self_pid = self()

    Task.start(fn ->
      safe_call(fn -> ProjectScanner.scan() end, {:ok, []})
      send(self_pid, :scan_complete)
    end)

    {:noreply, assign(socket, :scanning, true)}
  end

  # --- Selection events ---

  def handle_event("toggle_row", %{"path" => path}, socket) do
    selected = socket.assigns.selected_paths

    new_selected =
      if MapSet.member?(selected, path),
        do: MapSet.delete(selected, path),
        else: MapSet.put(selected, path)

    {:noreply, assign(socket, :selected_paths, new_selected)}
  end

  def handle_event("select_all", _params, socket) do
    all_paths = socket.assigns.projects |> Enum.map(& &1.path) |> MapSet.new()
    {:noreply, assign(socket, :selected_paths, all_paths)}
  end

  def handle_event("deselect_all", _params, socket) do
    {:noreply, assign(socket, :selected_paths, MapSet.new())}
  end

  def handle_event("range_select", %{"from" => from, "to" => to}, socket) do
    from_i = coerce_int(from)
    to_i = coerce_int(to)

    paths_in_range =
      socket.assigns.projects
      |> Enum.with_index()
      |> Enum.filter(fn {_, i} -> i >= from_i and i <= to_i end)
      |> Enum.map(fn {p, _} -> p.path end)
      |> MapSet.new()

    new_selected = MapSet.union(socket.assigns.selected_paths, paths_in_range)
    {:noreply, assign(socket, :selected_paths, new_selected)}
  end

  def handle_event("run_bulk_action", %{"action" => action_id}, socket) do
    paths = MapSet.to_list(socket.assigns.selected_paths)
    action = Enum.find(socket.assigns.catalog, &(&1.id == action_id))
    count = length(paths)

    Enum.each(paths, fn path ->
      safe_call(fn -> ActionEngine.run_action(action_id, path) end, {:error, :skipped})
    end)

    runs = safe_call(fn -> ActionEngine.list_runs() end, socket.assigns.runs)
    suffix = if count == 1, do: "", else: "s"

    {:noreply,
     socket
     |> assign(:selected_paths, MapSet.new())
     |> assign(:runs, runs)
     |> put_flash(:info, "Running #{action.name} on #{count} project#{suffix}")}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_collapsed: !socket.assigns.sidebar_collapsed)}
  end

  def handle_event("toggle_inspector", _params, socket) do
    {:noreply, assign(socket, inspector_open: !socket.assigns.inspector_open)}
  end

  # --- Components ---

  attr :value, :boolean, required: true

  defp status_cell(assigns) do
    ~H"""
    <span :if={@value} style="display: flex; align-items: center; justify-content: center;">
      <.icon name="hero-check-circle" class="size-4" style="color: var(--ccem-ok, #22c55e);" />
    </span>
    <span :if={!@value} style="display: flex; align-items: center; justify-content: center; opacity: 0.3;">
      <.icon name="hero-x-circle" class="size-4" style="color: var(--ccem-err, #ef4444);" />
    </span>
    """
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar><.sidebar_nav current_path="/actions" /></:sidebar>
      <:topbar><.top_bar project_name="CCEM APM" /></:topbar>
      <:main>
        <%!-- Page header --%>
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
          <div style="display: flex; align-items: center; gap: 10px;">
            <h1 style="margin: 0; font-size: 16px; font-weight: 600; color: var(--ccem-fg);">Actions</h1>
            <span style="font-size: 12px; color: var(--ccem-fg-muted);">Configure and apply APM integration to your projects</span>
          </div>
        </div>

        <%!-- Stat tiles --%>
        <div style="display: flex; gap: 12px; margin-bottom: 16px; flex-wrap: wrap;">
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Projects" value={to_string(length(@projects))} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Actions" value={to_string(length(@catalog))} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Recent Runs" value={to_string(length(@runs))} />
          </.card>
          <.card style="flex: 1; min-width: 120px; padding: 12px 16px;">
            <.stat_tile label="Selected" value={to_string(MapSet.size(@selected_paths))} />
          </.card>
        </div>

        <%!-- Projects Status Table --%>
        <div style="margin-bottom: 24px;">
          <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px;">
            <div style="display: flex; align-items: center; gap: 8px;">
              <span style="font-size: 11px; font-weight: 600; color: var(--ccem-fg-muted); text-transform: uppercase; letter-spacing: 0.05em;">Projects</span>
              <.badge :if={@projects != []} tone="neutral"><%= to_string(length(@projects)) %> found</.badge>
            </div>
            <.btn variant="ghost" size="xs" phx-click="scan_projects" disabled={@scanning}>
              <.icon name="hero-arrow-path" class={["size-3", @scanning && "animate-spin"]} />
              <%= if @scanning, do: "Scanning...", else: "Rescan" %>
            </.btn>
          </div>

          <.card padded={false}>
            <div :if={@projects == []} style="padding: 32px; text-align: center; color: var(--ccem-fg-muted); font-size: 13px;">
              No projects found.
              <button phx-click="scan_projects" style="color: var(--ccem-accent); background: none; border: none; cursor: pointer; padding: 0; margin-left: 4px;">Scan now</button>
            </div>

            <table
              :if={@projects != []}
              id="projects-select-table"
              phx-hook="ShiftSelect"
              style="width: 100%; font-size: 13px; border-collapse: collapse;"
            >
              <thead>
                <tr style="border-bottom: 1px solid var(--ccem-border); background: var(--ccem-surface-2);">
                  <th style="padding: 8px 12px; width: 32px;" data-no-select="true">
                    <input
                      type="checkbox"
                      style="cursor: pointer;"
                      phx-click={
                        if @projects != [] and MapSet.size(@selected_paths) == length(@projects),
                          do: "deselect_all",
                          else: "select_all"
                      }
                      checked={
                        @projects != [] and MapSet.size(@selected_paths) == length(@projects)
                      }
                    />
                  </th>
                  <th style="padding: 8px 16px; text-align: left; font-size: 11px; color: var(--ccem-fg-muted); font-weight: 500;">Project</th>
                  <th style="padding: 8px 16px; text-align: left; font-size: 11px; color: var(--ccem-fg-muted); font-weight: 500;">Stack</th>
                  <th style="padding: 8px 16px; text-align: center; font-size: 11px; color: var(--ccem-fg-muted); font-weight: 500;">Hooks</th>
                  <th style="padding: 8px 16px; text-align: center; font-size: 11px; color: var(--ccem-fg-muted); font-weight: 500;">Memory</th>
                  <th style="padding: 8px 16px; text-align: center; font-size: 11px; color: var(--ccem-fg-muted); font-weight: 500;">Config</th>
                  <th style="padding: 8px 16px; text-align: right; font-size: 11px; color: var(--ccem-fg-muted); font-weight: 500;">Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={{proj, index} <- Enum.with_index(@projects)}
                  data-row-index={index}
                  phx-click="toggle_row"
                  phx-value-path={proj.path}
                  style={[
                    "border-bottom: 1px solid var(--ccem-border); cursor: pointer; transition: background 0.1s;",
                    if(MapSet.member?(@selected_paths, proj.path),
                      do: "background: rgba(var(--ccem-accent-rgb, 99,102,241), 0.06);",
                      else: "")
                  ]}
                >
                  <td style="padding: 10px 12px;" data-no-select="true">
                    <input
                      type="checkbox"
                      style="pointer-events: none;"
                      checked={MapSet.member?(@selected_paths, proj.path)}
                      readonly
                    />
                  </td>
                  <td style="padding: 10px 16px;">
                    <div style="font-weight: 500; color: var(--ccem-fg);">{proj.name}</div>
                    <div style="font-size: 10px; color: var(--ccem-fg-subtle); font-family: monospace; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 300px;">{proj.path}</div>
                  </td>
                  <td style="padding: 10px 16px; font-size: 12px; color: var(--ccem-fg-muted);">{format_stack(proj.stack)}</td>
                  <td style="padding: 10px 16px; text-align: center;">
                    <.status_cell value={proj[:has_hooks] || false} />
                  </td>
                  <td style="padding: 10px 16px; text-align: center;">
                    <.status_cell value={proj[:has_memory_pointer] || false} />
                  </td>
                  <td style="padding: 10px 16px; text-align: center;">
                    <.status_cell value={proj[:has_apm_config] || false} />
                  </td>
                  <td style="padding: 10px 16px;" data-no-select="true">
                    <div style="display: flex; align-items: center; justify-content: flex-end; gap: 4px;">
                      <.btn
                        :for={action <- @catalog}
                        variant="ghost"
                        size="xs"
                        phx-click="open_run_modal"
                        phx-value-action={action.id}
                        phx-value-path={proj.path}
                        title={action.name}
                      >
                        <.icon name={action_icon(action.id)} class="size-3.5" />
                      </.btn>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </.card>
        </div>

        <%!-- Action Catalog --%>
        <div style="margin-bottom: 24px;">
          <h3 style="font-size: 11px; font-weight: 600; color: var(--ccem-fg-muted); text-transform: uppercase; letter-spacing: 0.05em; margin: 0 0 12px 0;">Action Catalog</h3>
          <div style="display: grid; grid-template-columns: repeat(2, 1fr); gap: 16px;">
            <.card :for={action <- @catalog} style="padding: 16px;">
              <div style="display: flex; align-items: flex-start; justify-content: space-between; margin-bottom: 8px;">
                <div>
                  <.badge tone={category_tone(action.category)} square={true}><%= action.category %></.badge>
                  <div style="font-weight: 500; color: var(--ccem-fg); margin-top: 4px;">{action.name}</div>
                </div>
              </div>
              <p style="font-size: 12px; color: var(--ccem-fg-muted); margin: 0 0 12px 0;">{action.description}</p>
              <.btn variant="primary" size="sm" phx-click="open_run_modal" phx-value-action={action.id} style="width: 100%;">
                Run
              </.btn>
            </.card>
          </div>
        </div>

        <%!-- Recent Runs --%>
        <div style="padding-bottom: 80px;">
          <h3 style="font-size: 11px; font-weight: 600; color: var(--ccem-fg-muted); text-transform: uppercase; letter-spacing: 0.05em; margin: 0 0 12px 0;">Recent Runs</h3>
          <div :if={@runs == []} style="font-size: 13px; color: var(--ccem-fg-muted);">
            No runs yet. Run an action above to get started.
          </div>
          <.card :if={@runs != []} padded={false}>
            <.data_table id="runs-table" rows={@runs}>
              <:col :let={row} label="Action"><%= row[:action_type] %></:col>
              <:col :let={row} label="Project"><span style="font-family: monospace; font-size: 11px; color: var(--ccem-fg-muted);"><%= Path.basename(row[:project_path] || "") %></span></:col>
              <:col :let={row} label="Status"><.badge tone={run_status_tone(row[:status])}><%= row[:status] %></.badge></:col>
              <:col :let={row} label="Started"><span style="font-size: 11px; color: var(--ccem-fg-subtle);"><%= row[:started_at] %></span></:col>
              <:col :let={row} label="Duration"><span style="color: var(--ccem-fg-muted);"><%= format_duration(row[:started_at], row[:completed_at]) %></span></:col>
              <:col :let={row} label="Result">
                <.btn variant="ghost" size="xs" phx-click="view_result" phx-value-id={row[:id]}>View</.btn>
              </:col>
            </.data_table>
          </.card>
        </div>
      </:main>
    </.page_layout>

    <%!-- Bulk Action Toolbar --%>
    <div
      :if={MapSet.size(@selected_paths) > 0}
      style="position: fixed; bottom: 0; left: 0; right: 0; background: var(--ccem-surface-1); border-top: 1px solid var(--ccem-accent-border, rgba(99,102,241,0.3)); padding: 12px 24px; display: flex; align-items: center; gap: 12px; z-index: 40; box-shadow: 0 -4px 16px rgba(0,0,0,0.2);"
    >
      <span style="font-size: 13px; font-weight: 500; color: var(--ccem-fg-muted);">
        {MapSet.size(@selected_paths)} selected
      </span>
      <div style="width: 1px; height: 20px; background: var(--ccem-border);"></div>
      <.btn variant="secondary" size="sm" phx-click="run_bulk_action" phx-value-action="update_hooks">
        <.icon name="hero-code-bracket" class="size-3.5" /> Update Hooks
      </.btn>
      <.btn variant="secondary" size="sm" phx-click="run_bulk_action" phx-value-action="add_memory_pointer">
        <.icon name="hero-bookmark" class="size-3.5" /> Add Memory
      </.btn>
      <.btn variant="secondary" size="sm" phx-click="run_bulk_action" phx-value-action="backfill_apm_config">
        <.icon name="hero-cog-6-tooth" class="size-3.5" /> Backfill Config
      </.btn>
      <.btn variant="secondary" size="sm" phx-click="run_bulk_action" phx-value-action="analyze_project">
        <.icon name="hero-magnifying-glass" class="size-3.5" /> Analyze
      </.btn>
      <div style="flex: 1;"></div>
      <.btn variant="ghost" size="sm" phx-click="deselect_all">
        <.icon name="hero-x-mark" class="size-3.5" /> Clear
      </.btn>
    </div>

    <%!-- Run Action Modal --%>
    <div
      :if={@show_modal and @selected_action}
      style="position: fixed; inset: 0; background: rgba(0,0,0,0.5); display: flex; align-items: center; justify-content: center; z-index: 50;"
    >
      <div style="background: var(--ccem-surface-1); border: 1px solid var(--ccem-border); border-radius: 12px; width: 66%; max-width: 640px; display: flex; flex-direction: column; max-height: 72vh;">
        <div style="display: flex; align-items: flex-start; justify-content: space-between; padding: 16px 20px; border-bottom: 1px solid var(--ccem-border); flex-shrink: 0;">
          <div>
            <div style="font-size: 13px; font-weight: 600; color: var(--ccem-fg);">{@selected_action.name}</div>
            <div style="font-size: 12px; color: var(--ccem-fg-muted); margin-top: 2px;">{@selected_action.description}</div>
          </div>
          <.btn variant="ghost" size="xs" phx-click="close_modal" style="margin-left: 16px; flex-shrink: 0;">
            <.icon name="hero-x-mark" class="size-3" />
          </.btn>
        </div>

        <div style="display: flex; flex-direction: column; min-height: 0; flex: 1;">
          <div style="padding: 8px 20px; flex-shrink: 0;">
            <span style="font-size: 11px; font-weight: 500; color: var(--ccem-fg-muted); text-transform: uppercase; letter-spacing: 0.05em;">Select a project</span>
          </div>

          <div :if={@projects == []} style="padding: 12px 20px; font-size: 12px; color: var(--ccem-fg-muted);">
            No projects found. Use the path input below or
            <button phx-click="scan_projects" style="color: var(--ccem-accent); background: none; border: none; cursor: pointer; padding: 0;">scan</button>
            first.
          </div>

          <div :if={@projects != []} style="overflow-y: auto; flex: 1; min-height: 0; border-bottom: 1px solid var(--ccem-border);">
            <button
              :for={proj <- @projects}
              phx-click="select_project"
              phx-value-path={proj.path}
              style={[
                "width: 100%; display: flex; align-items: center; gap: 12px; padding: 10px 20px; text-align: left; border-bottom: 1px solid rgba(var(--ccem-border-rgb,255,255,255),0.06); cursor: pointer; background: none; border-left: none; border-right: none; transition: background 0.1s;",
                if(@project_path == proj.path, do: "background: rgba(var(--ccem-accent-rgb, 99,102,241), 0.08);", else: "")
              ]}
            >
              <div style="flex: 1; min-width: 0;">
                <div style="font-size: 13px; font-weight: 500; color: var(--ccem-fg); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">{proj.name}</div>
                <div style="font-size: 10px; color: var(--ccem-fg-subtle); font-family: monospace; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">{proj.path}</div>
              </div>
              <.badge tone={if action_applied?(proj, @selected_action.id), do: "ok", else: "neutral"} square={true}>
                {if action_applied?(proj, @selected_action.id), do: "applied", else: "pending"}
              </.badge>
              <.icon :if={@project_path == proj.path} name="hero-check" class="size-4" style="color: var(--ccem-accent); flex-shrink: 0;" />
            </button>
          </div>
        </div>

        <form phx-submit="run_action" style="padding: 16px 20px; display: flex; flex-direction: column; gap: 12px; flex-shrink: 0;">
          <div>
            <label style="font-size: 12px; color: var(--ccem-fg-muted); display: block; margin-bottom: 6px;">
              Project path (pre-filled from selection above, or type manually)
            </label>
            <.ds_input type="text" name="project_path" value={@project_path} phx-change="update_path" placeholder="~/Developer/my-project" />
          </div>
          <div style="display: flex; justify-content: flex-end; gap: 8px;">
            <.btn variant="ghost" size="sm" phx-click="close_modal" type="button">Cancel</.btn>
            <.btn variant="primary" size="sm" type="submit" disabled={String.trim(@project_path) == ""}>Run Action</.btn>
          </div>
        </form>
      </div>
    </div>

    <%!-- Result Modal --%>
    <div
      :if={@selected_run}
      style="position: fixed; inset: 0; background: rgba(0,0,0,0.5); display: flex; align-items: center; justify-content: center; z-index: 50;"
    >
      <div style="background: var(--ccem-surface-1); border: 1px solid var(--ccem-border); border-radius: 12px; width: 66%; max-height: 60vh; display: flex; flex-direction: column;">
        <div style="display: flex; align-items: center; justify-content: space-between; padding: 12px 16px; border-bottom: 1px solid var(--ccem-border); flex-shrink: 0;">
          <span style="font-size: 13px; font-weight: 600; color: var(--ccem-fg);">
            {@selected_run.action_type} — {Path.basename(@selected_run.project_path)}
          </span>
          <.btn variant="ghost" size="xs" phx-click="close_modal">
            <.icon name="hero-x-mark" class="size-3" />
          </.btn>
        </div>
        <div style="padding: 16px; overflow: auto; flex: 1;">
          <p :if={@selected_run.error} style="color: var(--ccem-err, #ef4444); font-size: 13px;">{@selected_run.error}</p>
          <pre :if={!@selected_run.error} style="font-size: 11px; color: var(--ccem-ok, #22c55e); white-space: pre-wrap;">{inspect(@selected_run.result, pretty: true)}</pre>
        </div>
      </div>
    </div>
    """
  end

  # --- Private helpers ---

  defp load_projects do
    results = safe_call(fn -> ProjectScanner.get_results() end, [])

    Enum.map(results, fn proj ->
      status =
        safe_call(
          fn -> ActionEngine.project_status(proj.path) end,
          %{has_hooks: false, has_memory_pointer: false, has_apm_config: false}
        )

      Map.merge(proj, status)
    end)
  end

  defp coerce_int(v) when is_integer(v), do: v
  defp coerce_int(v) when is_binary(v), do: String.to_integer(v)
  defp coerce_int(_), do: 0

  defp safe_call(fun, default) do
    try do
      fun.()
    rescue
      _ -> default
    catch
      :exit, _ -> default
    end
  end

  defp action_applied?(_project, "analyze_project"), do: false
  defp action_applied?(project, "update_hooks"), do: project[:has_hooks] || false
  defp action_applied?(project, "add_memory_pointer"), do: project[:has_memory_pointer] || false
  defp action_applied?(project, "backfill_apm_config"), do: project[:has_apm_config] || false
  defp action_applied?(_, _), do: false

  defp action_icon("update_hooks"), do: "hero-code-bracket"
  defp action_icon("add_memory_pointer"), do: "hero-bookmark"
  defp action_icon("backfill_apm_config"), do: "hero-cog-6-tooth"
  defp action_icon("analyze_project"), do: "hero-magnifying-glass"
  defp action_icon(_), do: "hero-bolt"

  defp format_stack([]), do: "—"
  defp format_stack(stack) when is_list(stack), do: Enum.join(stack, ", ")
  defp format_stack(stack) when is_binary(stack), do: stack
  defp format_stack(_), do: "—"

  defp run_status_tone("completed"), do: "ok"
  defp run_status_tone("failed"), do: "err"
  defp run_status_tone("running"), do: "info"
  defp run_status_tone(_), do: "neutral"

  defp category_tone("hooks"), do: "warn"
  defp category_tone("memory"), do: "iris"
  defp category_tone("config"), do: "ok"
  defp category_tone("analysis"), do: "accent"
  defp category_tone(_), do: "neutral"

  defp format_duration(nil, _), do: "—"
  defp format_duration(_, nil), do: "running"

  defp format_duration(started, completed) do
    case {DateTime.from_iso8601(started), DateTime.from_iso8601(completed)} do
      {{:ok, s, _}, {:ok, c, _}} ->
        diff = DateTime.diff(c, s)
        "#{diff}s"

      _ ->
        "—"
    end
  end
end
