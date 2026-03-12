defmodule ApmV5Web.ActionsLive do
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
     |> assign(:selected_paths, MapSet.new())}
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

  # --- Components ---

  attr :value, :boolean, required: true

  defp status_cell(assigns) do
    ~H"""
    <span :if={@value} class="flex items-center justify-center">
      <.icon name="hero-check-circle" class="size-4 text-success" />
    </span>
    <span :if={!@value} class="flex items-center justify-center">
      <.icon name="hero-x-circle" class="size-4 text-error/50" />
    </span>
    """
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <%!-- Sidebar --%>
      <.sidebar_nav current_path="/actions" />

      <%!-- Main content --%>
      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Header --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Actions</h2>
            <span class="text-xs text-base-content/40">
              Configure and apply APM integration to your projects
            </span>
          </div>
        </header>

        <%!-- Scrollable body — extra bottom padding leaves room for the bulk toolbar --%>
        <div class="flex-1 overflow-auto p-4 space-y-6 pb-24">

          <%!-- Projects Status Table --%>
          <div>
            <div class="flex items-center justify-between mb-3">
              <h3 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider">
                Projects
                <span :if={@projects != []} class="ml-1 text-base-content/30 normal-case">
                  — {length(@projects)} found
                </span>
              </h3>
              <button
                phx-click="scan_projects"
                disabled={@scanning}
                class="btn btn-ghost btn-xs text-base-content/50"
              >
                <.icon name="hero-arrow-path" class={["size-3", @scanning && "animate-spin"]} />
                {if @scanning, do: "Scanning...", else: "Rescan"}
              </button>
            </div>

            <div class="bg-base-200 rounded-lg border border-base-300 overflow-hidden">
              <div :if={@projects == []} class="p-8 text-center text-base-content/30 text-sm">
                No projects found.
                <button phx-click="scan_projects" class="link link-primary ml-1">Scan now</button>
              </div>

              <table
                :if={@projects != []}
                id="projects-select-table"
                phx-hook="ShiftSelect"
                class="w-full text-sm"
              >
                <thead>
                  <tr class="border-b border-base-300 bg-base-300/30">
                    <th class="px-3 py-2 w-8" data-no-select="true">
                      <%!-- Select-all / deselect-all header checkbox --%>
                      <input
                        type="checkbox"
                        class="checkbox checkbox-xs"
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
                    <th class="px-4 py-2 text-left text-xs text-base-content/50 font-medium">
                      Project
                    </th>
                    <th class="px-4 py-2 text-left text-xs text-base-content/50 font-medium">
                      Stack
                    </th>
                    <th class="px-4 py-2 text-center text-xs text-base-content/50 font-medium">
                      Hooks
                    </th>
                    <th class="px-4 py-2 text-center text-xs text-base-content/50 font-medium">
                      Memory
                    </th>
                    <th class="px-4 py-2 text-center text-xs text-base-content/50 font-medium">
                      Config
                    </th>
                    <th class="px-4 py-2 text-right text-xs text-base-content/50 font-medium">
                      Actions
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={{proj, index} <- Enum.with_index(@projects)}
                    data-row-index={index}
                    phx-click="toggle_row"
                    phx-value-path={proj.path}
                    class={[
                      "border-b border-base-300/50 cursor-pointer transition-colors select-none",
                      MapSet.member?(@selected_paths, proj.path) &&
                        "bg-primary/5 hover:bg-primary/10" ||
                        "hover:bg-base-300/20"
                    ]}
                  >
                    <%!-- Row checkbox — stops propagation so toggle_row doesn't double-fire --%>
                    <td class="px-3 py-3" data-no-select="true">
                      <input
                        type="checkbox"
                        class="checkbox checkbox-xs pointer-events-none"
                        checked={MapSet.member?(@selected_paths, proj.path)}
                        readonly
                      />
                    </td>
                    <td class="px-4 py-3">
                      <div class="font-medium text-base-content text-sm">{proj.name}</div>
                      <div class="text-[10px] text-base-content/40 font-mono truncate max-w-xs">
                        {proj.path}
                      </div>
                    </td>
                    <td class="px-4 py-3 text-xs text-base-content/60">
                      {format_stack(proj.stack)}
                    </td>
                    <td class="px-4 py-3 text-center">
                      <.status_cell value={proj[:has_hooks] || false} />
                    </td>
                    <td class="px-4 py-3 text-center">
                      <.status_cell value={proj[:has_memory_pointer] || false} />
                    </td>
                    <td class="px-4 py-3 text-center">
                      <.status_cell value={proj[:has_apm_config] || false} />
                    </td>
                    <%!-- Per-row action buttons — LiveView delegation fires the button's phx-click first,
                         so the TR's toggle_row does not fire when a button is clicked. --%>
                    <td class="px-4 py-3" data-no-select="true">
                      <div class="flex items-center justify-end gap-1">
                        <button
                          :for={action <- @catalog}
                          phx-click="open_run_modal"
                          phx-value-action={action.id}
                          phx-value-path={proj.path}
                          class="btn btn-ghost btn-xs text-base-content/50 hover:text-base-content tooltip tooltip-left"
                          data-tip={action.name}
                        >
                          <.icon name={action_icon(action.id)} class="size-3.5" />
                        </button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <%!-- Action Catalog --%>
          <div>
            <h3 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">
              Action Catalog
            </h3>
            <div class="grid grid-cols-2 gap-4">
              <div :for={action <- @catalog} class="bg-base-200 border border-base-300 rounded-xl p-4">
                <div class="flex items-start justify-between mb-2">
                  <div>
                    <span class={"text-xs font-semibold uppercase #{category_color(action.category)}"}>
                      {action.category}
                    </span>
                    <h3 class="font-medium mt-0.5 text-base-content">{action.name}</h3>
                  </div>
                </div>
                <p class="text-xs text-base-content/60 mb-3">{action.description}</p>
                <button
                  phx-click="open_run_modal"
                  phx-value-action={action.id}
                  class="btn btn-primary btn-sm w-full"
                >
                  Run
                </button>
              </div>
            </div>
          </div>

          <%!-- Recent Runs --%>
          <div>
            <h3 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">
              Recent Runs
            </h3>
            <div :if={@runs == []} class="text-base-content/40 text-sm">
              No runs yet. Run an action above to get started.
            </div>
            <table :if={@runs != []} class="w-full text-sm">
              <thead>
                <tr class="text-left text-base-content/50 border-b border-base-300">
                  <th class="pb-3 pr-4">Action</th>
                  <th class="pb-3 pr-4">Project</th>
                  <th class="pb-3 pr-4">Status</th>
                  <th class="pb-3 pr-4">Started</th>
                  <th class="pb-3 pr-4">Duration</th>
                  <th class="pb-3">Result</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={run <- @runs}
                  class="border-b border-base-300/50 hover:bg-base-200/50"
                >
                  <td class="py-3 pr-4 font-medium text-base-content">{run.action_type}</td>
                  <td class="py-3 pr-4 text-base-content/60 max-w-xs truncate font-mono text-xs">
                    {Path.basename(run.project_path)}
                  </td>
                  <td class="py-3 pr-4">
                    <span class={run_status_class(run.status)}>{run.status}</span>
                  </td>
                  <td class="py-3 pr-4 text-base-content/40 text-xs">{run.started_at}</td>
                  <td class="py-3 pr-4 text-base-content/60">
                    {format_duration(run.started_at, run.completed_at)}
                  </td>
                  <td class="py-3">
                    <button phx-click="view_result" phx-value-id={run.id} class="btn btn-ghost btn-xs">
                      View
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

        </div>
      </div>
    </div>

    <%!-- Bulk Action Toolbar — fixed bottom bar, visible when rows are selected --%>
    <div
      :if={MapSet.size(@selected_paths) > 0}
      class="fixed bottom-0 inset-x-0 bg-base-200 border-t border-primary/30 px-6 py-3 flex items-center gap-3 z-40 shadow-xl"
    >
      <span class="text-sm font-medium text-base-content/70 tabular-nums">
        {MapSet.size(@selected_paths)} selected
      </span>
      <div class="w-px h-5 bg-base-300" />
      <button
        phx-click="run_bulk_action"
        phx-value-action="update_hooks"
        class="btn btn-sm btn-outline gap-1.5"
      >
        <.icon name="hero-code-bracket" class="size-3.5" />
        Update Hooks
      </button>
      <button
        phx-click="run_bulk_action"
        phx-value-action="add_memory_pointer"
        class="btn btn-sm btn-outline gap-1.5"
      >
        <.icon name="hero-bookmark" class="size-3.5" />
        Add Memory
      </button>
      <button
        phx-click="run_bulk_action"
        phx-value-action="backfill_apm_config"
        class="btn btn-sm btn-outline gap-1.5"
      >
        <.icon name="hero-cog-6-tooth" class="size-3.5" />
        Backfill Config
      </button>
      <button
        phx-click="run_bulk_action"
        phx-value-action="analyze_project"
        class="btn btn-sm btn-outline gap-1.5"
      >
        <.icon name="hero-magnifying-glass" class="size-3.5" />
        Analyze
      </button>
      <div class="flex-1" />
      <button
        phx-click="deselect_all"
        class="btn btn-ghost btn-sm text-base-content/40 gap-1.5"
      >
        <.icon name="hero-x-mark" class="size-3.5" />
        Clear
      </button>
    </div>

    <%!-- Run Action Modal --%>
    <div
      :if={@show_modal and @selected_action}
      class="fixed inset-0 bg-black/50 flex items-center justify-center z-50"
    >
      <div class="bg-base-200 rounded-xl border border-base-300 w-2/3 max-w-2xl flex flex-col max-h-[72vh]">
        <%!-- Modal header --%>
        <div class="flex items-start justify-between px-5 py-4 border-b border-base-300 flex-shrink-0">
          <div>
            <h3 class="text-sm font-semibold text-base-content">{@selected_action.name}</h3>
            <p class="text-xs text-base-content/50 mt-0.5">{@selected_action.description}</p>
          </div>
          <button phx-click="close_modal" class="btn btn-ghost btn-xs btn-circle ml-4 flex-shrink-0">
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </div>

        <%!-- Project picker list --%>
        <div class="flex flex-col min-h-0 flex-1">
          <div class="px-5 py-2 flex-shrink-0">
            <span class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
              Select a project
            </span>
          </div>

          <div :if={@projects == []} class="px-5 pb-3 text-xs text-base-content/40">
            No projects found. Use the path input below or
            <button phx-click="scan_projects" class="link link-primary">scan</button>
            first.
          </div>

          <div :if={@projects != []} class="overflow-y-auto flex-1 min-h-0 border-b border-base-300">
            <button
              :for={proj <- @projects}
              phx-click="select_project"
              phx-value-path={proj.path}
              class={[
                "w-full flex items-center gap-3 px-5 py-2.5 text-left hover:bg-base-300/40 transition-colors border-b border-base-300/40 last:border-0",
                @project_path == proj.path && "bg-primary/10"
              ]}
            >
              <div class="flex-1 min-w-0">
                <div class="text-sm font-medium text-base-content truncate">{proj.name}</div>
                <div class="text-[10px] text-base-content/40 font-mono truncate">{proj.path}</div>
              </div>
              <span class={[
                "badge badge-xs flex-shrink-0",
                action_applied?(proj, @selected_action.id) && "badge-success" || "badge-ghost opacity-60"
              ]}>
                {if action_applied?(proj, @selected_action.id), do: "applied", else: "pending"}
              </span>
              <.icon
                :if={@project_path == proj.path}
                name="hero-check"
                class="size-4 text-primary flex-shrink-0"
              />
            </button>
          </div>
        </div>

        <%!-- Path input and submit --%>
        <form phx-submit="run_action" class="px-5 py-4 space-y-3 flex-shrink-0">
          <div>
            <label class="text-xs text-base-content/50 block mb-1.5">
              Project path (pre-filled from selection above, or type manually)
            </label>
            <input
              type="text"
              name="project_path"
              value={@project_path}
              phx-change="update_path"
              placeholder="~/Developer/my-project"
              class="input input-bordered input-sm w-full bg-base-100"
            />
          </div>
          <div class="flex justify-end gap-2">
            <button type="button" phx-click="close_modal" class="btn btn-ghost btn-sm">Cancel</button>
            <button
              type="submit"
              class="btn btn-primary btn-sm"
              disabled={String.trim(@project_path) == ""}
            >
              Run Action
            </button>
          </div>
        </form>
      </div>
    </div>

    <%!-- Result Modal --%>
    <div
      :if={@selected_run}
      class="fixed inset-0 bg-black/50 flex items-center justify-center z-50"
    >
      <div class="bg-base-200 rounded-xl border border-base-300 w-2/3 max-h-[60vh] flex flex-col">
        <div class="flex items-center justify-between px-4 py-3 border-b border-base-300 flex-shrink-0">
          <h3 class="text-sm font-semibold text-base-content">
            {@selected_run.action_type} — {Path.basename(@selected_run.project_path)}
          </h3>
          <button phx-click="close_modal" class="btn btn-ghost btn-xs btn-circle">
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </div>
        <div class="p-4 overflow-auto flex-1">
          <p :if={@selected_run.error} class="text-error text-sm">{@selected_run.error}</p>
          <pre
            :if={!@selected_run.error}
            class="text-xs text-success whitespace-pre-wrap"
          >{inspect(@selected_run.result, pretty: true)}</pre>
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

  defp run_status_class("completed"), do: "badge badge-xs badge-success"
  defp run_status_class("failed"), do: "badge badge-xs badge-error"
  defp run_status_class("running"), do: "badge badge-xs badge-info"
  defp run_status_class(_), do: "badge badge-xs badge-ghost"

  defp category_color("hooks"), do: "text-yellow-400"
  defp category_color("memory"), do: "text-blue-400"
  defp category_color("config"), do: "text-green-400"
  defp category_color("analysis"), do: "text-purple-400"
  defp category_color(_), do: "text-base-content/40"

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
