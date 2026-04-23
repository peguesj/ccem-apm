defmodule ApmV5Web.RalphPluginLive do
  @moduledoc """
  LiveView for the Ralph plugin page at /plugins/ralph.

  Three tabs:
    - PRD      — reads ~/.claude/skills/ralph/prd.json and displays user stories with pass/fail status
    - Formation — links to /formation filtered for ralph-related formations
    - History   — recent ralph-related background tasks from BackgroundTasksStore
  """

  use ApmV5Web, :live_view

  alias ApmV5.BackgroundTasksStore
  alias ApmV5.ConfigLoader
  alias ApmV5.Ralph

  @pubsub_topic "tasks:updated"
  @prd_paths [
    "~/.claude/skills/ralph/prd.json",
    "~/.claude/prd.json"
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic)
    end

    socket =
      socket
      |> assign(:page_title, "Ralph Plugin")
      |> assign(:active_tab, "prd")
      |> assign(:current_path, "/plugins/ralph")
      |> assign(:active_skill_count, skill_count())
      |> load_prd_data()
      |> load_history_tasks()

    {:ok, socket |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  @impl true
  def handle_params(%{"tab" => tab}, _uri, socket)
      when tab in ["prd", "formation", "history"] do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:task_updated, _task}, socket) do
    {:noreply, load_history_tasks(socket)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("reload_prd", _params, socket) do
    {:noreply, load_prd_data(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <.sidebar_nav current_path={@current_path} skill_count={@active_skill_count} />

      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Header --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0 relative z-10">
          <div class="flex items-center gap-3">
            <span class="inline-flex items-center justify-center w-6 h-6 rounded bg-primary/10">
              <.icon name="hero-document-text" class="size-4 text-primary" />
            </span>
            <h2 class="text-sm font-semibold text-base-content">Ralph Plugin</h2>
            <div class="badge badge-sm badge-ghost">v1.0.0</div>
          </div>
          <div class="flex items-center gap-2">
            <button
              :if={@active_tab == "prd"}
              class="btn btn-ghost btn-xs"
              phx-click="reload_prd"
            >
              Reload
            </button>
          </div>
        </header>

        <%!-- Tab bar --%>
        <div class="bg-base-200 border-b border-base-300 px-4 flex gap-1 flex-shrink-0">
          <.tab_btn tab="prd" active_tab={@active_tab} label="PRD" />
          <.tab_btn tab="formation" active_tab={@active_tab} label="Formation" />
          <.tab_btn tab="history" active_tab={@active_tab} label="History" />
        </div>

        <%!-- Content --%>
        <div class="flex-1 overflow-y-auto p-6">
          <%!-- PRD Tab --%>
          <div :if={@active_tab == "prd"}>
            <div :if={@prd_error} class="alert alert-warning mb-4">
              <.icon name="hero-exclamation-triangle" class="size-4" />
              <span>No prd.json found — checked: {@prd_paths_checked}</span>
            </div>

            <div :if={not @prd_error}>
              <div class="mb-4 flex items-center gap-3">
                <div class="text-sm text-base-content/60">
                  <span class="font-medium text-base-content">{@prd_data.project}</span>
                  <span :if={@prd_data.branch != ""} class="ml-2 badge badge-sm badge-ghost font-mono">
                    {@prd_data.branch}
                  </span>
                </div>
                <div class="ml-auto flex gap-2">
                  <div class="badge badge-success badge-sm">{@prd_data.passed} passed</div>
                  <div class="badge badge-ghost badge-sm">{@prd_data.total} total</div>
                </div>
              </div>

              <div :if={@prd_data.description != ""} class="text-xs text-base-content/50 mb-4">
                {@prd_data.description}
              </div>

              <%!-- Progress bar --%>
              <div :if={@prd_data.total > 0} class="mb-6">
                <div class="flex justify-between text-xs text-base-content/50 mb-1">
                  <span>Progress</span>
                  <span>{progress_pct(@prd_data)}%</span>
                </div>
                <div class="w-full bg-base-300 rounded-full h-2">
                  <div
                    class="bg-success h-2 rounded-full transition-all"
                    style={"width: #{progress_pct(@prd_data)}%"}
                  />
                </div>
              </div>

              <%!-- Story list --%>
              <div class="space-y-2">
                <div
                  :for={story <- @prd_data.stories}
                  class="bg-base-200 rounded-lg p-3 flex items-start gap-3"
                >
                  <div class="flex-shrink-0 mt-0.5">
                    <span :if={story["passes"] == true} class="inline-block w-4 h-4 rounded-full bg-success/20 flex items-center justify-center">
                      <.icon name="hero-check" class="size-3 text-success" />
                    </span>
                    <span :if={story["passes"] != true} class="inline-block w-4 h-4 rounded-full bg-error/20 flex items-center justify-center">
                      <.icon name="hero-x-mark" class="size-3 text-error" />
                    </span>
                  </div>
                  <div class="flex-1 min-w-0">
                    <div class="flex items-center gap-2 flex-wrap">
                      <span class="text-xs font-mono text-base-content/40">
                        {story["id"] || "—"}
                      </span>
                      <span class="text-sm font-medium text-base-content truncate">
                        {story["title"] || "(untitled)"}
                      </span>
                      <span
                        :if={story["passes"] == true}
                        class="badge badge-success badge-xs ml-auto"
                      >
                        passed
                      </span>
                      <span
                        :if={story["passes"] != true}
                        class="badge badge-error badge-xs ml-auto"
                      >
                        pending
                      </span>
                    </div>
                    <div :if={story["description"]} class="text-xs text-base-content/50 mt-0.5 line-clamp-2">
                      {story["description"]}
                    </div>
                  </div>
                </div>

                <div :if={@prd_data.stories == []} class="text-center text-base-content/30 py-12 text-sm">
                  No user stories found in prd.json
                </div>
              </div>

              <div class="mt-4 text-xs text-base-content/30">
                Source: {@prd_source_path}
              </div>
            </div>
          </div>

          <%!-- Formation Tab --%>
          <div :if={@active_tab == "formation"}>
            <div class="mb-4 text-sm text-base-content/60">
              View active formations associated with Ralph loops.
            </div>
            <div class="space-y-3">
              <a
                href="/formation"
                class="flex items-center gap-3 bg-base-200 rounded-lg p-4 hover:bg-base-300 transition-colors group"
              >
                <.icon name="hero-rectangle-group" class="size-5 text-primary" />
                <div class="flex-1">
                  <div class="text-sm font-medium group-hover:text-primary transition-colors">All Formations</div>
                  <div class="text-xs text-base-content/50">View all active and completed formations</div>
                </div>
                <.icon name="hero-arrow-right" class="size-4 text-base-content/30 group-hover:text-primary transition-colors" />
              </a>
              <a
                href="/formation?filter=ralph"
                class="flex items-center gap-3 bg-base-200 rounded-lg p-4 hover:bg-base-300 transition-colors group"
              >
                <.icon name="hero-document-text" class="size-5 text-secondary" />
                <div class="flex-1">
                  <div class="text-sm font-medium group-hover:text-secondary transition-colors">Ralph Formations</div>
                  <div class="text-xs text-base-content/50">Filter formations with "ralph" in their ID or task subject</div>
                </div>
                <.icon name="hero-arrow-right" class="size-4 text-base-content/30 group-hover:text-secondary transition-colors" />
              </a>
              <a
                href="/ralph"
                class="flex items-center gap-3 bg-base-200 rounded-lg p-4 hover:bg-base-300 transition-colors group"
              >
                <.icon name="hero-share" class="size-5 text-accent" />
                <div class="flex-1">
                  <div class="text-sm font-medium group-hover:text-accent transition-colors">Ralph Flowchart</div>
                  <div class="text-xs text-base-content/50">View the D3.js Ralph methodology flowchart</div>
                </div>
                <.icon name="hero-arrow-right" class="size-4 text-base-content/30 group-hover:text-accent transition-colors" />
              </a>
            </div>
          </div>

          <%!-- History Tab --%>
          <div :if={@active_tab == "history"}>
            <div class="mb-4 text-sm text-base-content/60">
              Recent background tasks related to Ralph loops.
            </div>

            <div :if={@history_tasks == []} class="text-center text-base-content/30 py-12 text-sm">
              No ralph-related background tasks found.
            </div>

            <div class="space-y-2">
              <div
                :for={task <- @history_tasks}
                class="bg-base-200 rounded-lg p-3 flex items-start gap-3"
              >
                <div class="flex-shrink-0 mt-0.5">
                  <span class={[
                    "badge badge-xs",
                    task_status_class(task[:status] || task["status"])
                  ]}>
                    {task[:status] || task["status"] || "unknown"}
                  </span>
                </div>
                <div class="flex-1 min-w-0">
                  <div class="text-sm font-medium text-base-content truncate">
                    {task[:agent_name] || task["agent_name"] || task[:name] || task["name"] || "ralph task"}
                  </div>
                  <div class="text-xs text-base-content/50 mt-0.5">
                    {task[:project] || task["project"] || ""}
                    <span :if={task[:runtime_ms] || task["runtime_ms"]} class="ml-2">
                      {format_runtime(task[:runtime_ms] || task["runtime_ms"])}
                    </span>
                  </div>
                  <div :if={task[:agent_definition] || task["agent_definition"]} class="text-xs text-base-content/30 mt-0.5 line-clamp-1 font-mono">
                    {task[:agent_definition] || task["agent_definition"]}
                  </div>
                </div>
                <a
                  href="/tasks"
                  class="btn btn-ghost btn-xs flex-shrink-0"
                  title="View in Tasks"
                >
                  <.icon name="hero-arrow-top-right-on-square" class="size-3" />
                </a>
              </div>
            </div>

            <div class="mt-4">
              <a href="/tasks" class="btn btn-ghost btn-sm w-full">
                View All Background Tasks
              </a>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Private helpers ---

  defp tab_btn(assigns) do
    active = assigns.active_tab == assigns.tab

    assigns = assign(assigns, :is_active, active)

    ~H"""
    <button
      class={[
        "px-3 py-2 text-xs font-medium border-b-2 transition-colors",
        @is_active && "border-primary text-primary",
        !@is_active && "border-transparent text-base-content/50 hover:text-base-content"
      ]}
      phx-click="switch_tab"
      phx-value-tab={@tab}
    >
      {@label}
    </button>
    """
  end

  @spec load_prd_data(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_prd_data(socket) do
    expanded_paths = Enum.map(@prd_paths, &Path.expand/1)
    paths_checked = Enum.join(expanded_paths, ", ")

    case find_and_load_prd(expanded_paths) do
      {:ok, path, data} ->
        socket
        |> assign(:prd_data, data)
        |> assign(:prd_error, false)
        |> assign(:prd_source_path, path)
        |> assign(:prd_paths_checked, paths_checked)

      :error ->
        config_path = config_prd_path()
        {final_error, final_data, final_path} =
          if config_path do
            case Ralph.load(config_path) do
              {:ok, data} -> {false, data, config_path}
              _ -> {true, Ralph.load(nil) |> elem(1), ""}
            end
          else
            {:ok, empty} = Ralph.load(nil)
            {true, empty, ""}
          end

        socket
        |> assign(:prd_data, final_data)
        |> assign(:prd_error, final_error)
        |> assign(:prd_source_path, final_path)
        |> assign(:prd_paths_checked, paths_checked)
    end
  end

  @spec find_and_load_prd([String.t()]) :: {:ok, String.t(), map()} | :error
  defp find_and_load_prd([]), do: :error

  defp find_and_load_prd([path | rest]) do
    if File.exists?(path) do
      case Ralph.load(path) do
        {:ok, data} -> {:ok, path, data}
        _ -> find_and_load_prd(rest)
      end
    else
      find_and_load_prd(rest)
    end
  end

  @spec load_history_tasks(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_history_tasks(socket) do
    tasks =
      try do
        BackgroundTasksStore.list_tasks(%{})
        |> Enum.filter(&ralph_task?/1)
        |> Enum.sort_by(fn t ->
          t[:started_at] || t["started_at"] || ""
        end, :desc)
        |> Enum.take(20)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    assign(socket, :history_tasks, tasks)
  end

  @spec ralph_task?(map()) :: boolean()
  defp ralph_task?(task) do
    fields = [
      task[:agent_name], task["agent_name"],
      task[:agent_definition], task["agent_definition"],
      task[:name], task["name"],
      task[:project], task["project"]
    ]

    Enum.any?(fields, fn v ->
      is_binary(v) && String.contains?(String.downcase(v), "ralph")
    end)
  end

  @spec config_prd_path() :: String.t() | nil
  defp config_prd_path do
    config = ConfigLoader.get_config()
    Map.get(config, "prd_path")
  rescue
    _ -> nil
  end

  @spec progress_pct(map()) :: non_neg_integer()
  defp progress_pct(%{total: 0}), do: 0
  defp progress_pct(%{passed: passed, total: total}), do: round(passed / total * 100)

  @spec task_status_class(String.t() | nil) :: String.t()
  defp task_status_class("running"), do: "badge-warning"
  defp task_status_class("completed"), do: "badge-success"
  defp task_status_class("failed"), do: "badge-error"
  defp task_status_class(_), do: "badge-ghost"

  @spec format_runtime(non_neg_integer() | nil) :: String.t()
  defp format_runtime(nil), do: ""
  defp format_runtime(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_runtime(ms) when ms < 60_000, do: "#{div(ms, 1_000)}s"
  defp format_runtime(ms), do: "#{div(ms, 60_000)}m #{rem(div(ms, 1_000), 60)}s"

  @spec skill_count() :: non_neg_integer()
  defp skill_count do
    try do
      map_size(ApmV5.SkillTracker.get_skill_catalog())
    catch
      :exit, _ -> 0
    end
  end
end
