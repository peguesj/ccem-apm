defmodule ApmV4Web.ActionsLive do
  use ApmV4Web, :live_view

  alias ApmV4.ActionEngine

  @refresh_interval 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end

    catalog = try do ActionEngine.list_catalog() rescue _ -> [] catch :exit, _ -> [] end
    runs = try do ActionEngine.list_runs() rescue _ -> [] catch :exit, _ -> [] end

    {:ok,
     socket
     |> assign(:page_title, "Actions")
     |> assign(:catalog, catalog)
     |> assign(:runs, runs)
     |> assign(:show_modal, false)
     |> assign(:selected_action, nil)
     |> assign(:project_path, "")
     |> assign(:selected_run, nil)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    runs = try do ActionEngine.list_runs() rescue _ -> socket.assigns.runs catch :exit, _ -> socket.assigns.runs end
    {:noreply, assign(socket, :runs, runs)}
  end

  @impl true
  def handle_event("open_run_modal", %{"action" => action_id}, socket) do
    action = Enum.find(socket.assigns.catalog, &(&1.id == action_id))
    {:noreply, socket |> assign(:show_modal, true) |> assign(:selected_action, action) |> assign(:project_path, "")}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, socket |> assign(:show_modal, false) |> assign(:selected_action, nil) |> assign(:selected_run, nil)}
  end

  def handle_event("update_path", %{"project_path" => path}, socket) do
    {:noreply, assign(socket, :project_path, path)}
  end

  def handle_event("run_action", %{"project_path" => path}, socket) do
    action = socket.assigns.selected_action
    result =
      try do
        ActionEngine.run_action(action.id, path)
      rescue
        _ -> {:error, "ActionEngine offline"}
      catch
        :exit, _ -> {:error, "ActionEngine offline"}
      end

    case result do
      {:ok, _run_id} ->
        runs = try do ActionEngine.list_runs() rescue _ -> socket.assigns.runs catch :exit, _ -> socket.assigns.runs end
        {:noreply,
         socket
         |> assign(:show_modal, false)
         |> assign(:selected_action, nil)
         |> assign(:runs, runs)
         |> put_flash(:info, "Action started: #{action.name}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{reason}")}
    end
  end

  def handle_event("view_result", %{"id" => run_id}, socket) do
    run =
      try do
        case ActionEngine.get_run(run_id) do
          {:ok, r} -> r
          _ -> nil
        end
      rescue _ -> nil
      catch :exit, _ -> nil
      end
    {:noreply, assign(socket, :selected_run, run)}
  end

  # --- Components ---

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :href, :string, required: true
  attr :badge, :any, default: nil

  defp nav_item(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "flex items-center gap-3 px-3 py-2 rounded text-sm transition-colors",
        @active && "bg-primary/10 text-primary font-medium",
        !@active && "text-base-content/60 hover:text-base-content hover:bg-base-300"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
      <span :if={@badge && @badge > 0} class="badge badge-xs badge-primary ml-auto">{@badge}</span>
    </a>
    """
  end

  # --- Helpers ---

  defp run_status_class("completed"), do: "badge badge-green"
  defp run_status_class("failed"), do: "badge badge-red"
  defp run_status_class("running"), do: "badge badge-blue"
  defp run_status_class(_), do: "badge badge-gray"

  defp category_color("hooks"), do: "text-yellow-400"
  defp category_color("memory"), do: "text-blue-400"
  defp category_color("config"), do: "text-green-400"
  defp category_color("analysis"), do: "text-purple-400"
  defp category_color(_), do: "text-gray-400"

  defp format_duration(nil, _), do: "-"
  defp format_duration(started, completed) do
    case {DateTime.from_iso8601(started), DateTime.from_iso8601(completed)} do
      {{:ok, s, _}, {:ok, c, _}} ->
        diff = DateTime.diff(c, s)
        "#{diff}s"
      _ -> "-"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <%!-- Sidebar --%>
      <aside class="w-56 bg-base-200 border-r border-base-300 flex flex-col flex-shrink-0">
        <div class="p-4 border-b border-base-300">
          <h1 class="text-lg font-bold text-primary flex items-center gap-2">
            <span class="inline-block w-2 h-2 rounded-full bg-success animate-pulse"></span>
            CCEM APM v4
          </h1>
          <p class="text-xs text-base-content/50 mt-1">Agent Performance Monitor</p>
        </div>
        <nav class="flex-1 p-2 space-y-1 overflow-y-auto">
          <.nav_item icon="hero-squares-2x2" label="Dashboard" active={false} href="/" />
          <.nav_item icon="hero-globe-alt" label="All Projects" active={false} href="/apm-all" />
          <.nav_item icon="hero-rectangle-group" label="Formations" active={false} href="/formation" />
          <.nav_item icon="hero-clock" label="Timeline" active={false} href="/timeline" />
          <.nav_item icon="hero-bell" label="Notifications" active={false} href="/notifications" />
          <.nav_item icon="hero-queue-list" label="Background Tasks" active={false} href="/tasks" />
          <.nav_item icon="hero-magnifying-glass" label="Project Scanner" active={false} href="/scanner" />
          <.nav_item icon="hero-bolt" label="Actions" active={true} href="/actions" />
          <.nav_item icon="hero-sparkles" label="Skills" active={false} href="/skills" />
          <.nav_item icon="hero-arrow-path" label="Ralph" active={false} href="/ralph" />
          <.nav_item icon="hero-signal" label="Ports" active={false} href="/ports" />
          <.nav_item icon="hero-book-open" label="Docs" active={false} href="/docs" />
        </nav>
      </aside>

      <%!-- Main content --%>
      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Header --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center px-4 flex-shrink-0">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Actions</h2>
            <span class="text-xs text-base-content/40">Run predefined actions to configure and update project APM integration</span>
          </div>
        </header>

        <div class="flex-1 overflow-auto p-4 space-y-6">
          <%!-- Action Catalog --%>
          <div>
            <h3 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">Action Catalog</h3>
            <div class="grid grid-cols-2 gap-4">
              <%= for action <- @catalog do %>
                <div class="bg-base-200 border border-base-300 rounded-xl p-4">
                  <div class="flex items-start justify-between mb-2">
                    <div>
                      <span class={"text-xs font-semibold uppercase #{category_color(action.category)}"}>
                        <%= action.category %>
                      </span>
                      <h3 class="font-medium mt-0.5 text-base-content"><%= action.name %></h3>
                    </div>
                  </div>
                  <p class="text-xs text-base-content/60 mb-3"><%= action.description %></p>
                  <button
                    phx-click="open_run_modal"
                    phx-value-action={action.id}
                    class="btn btn-primary btn-sm w-full"
                  >
                    Run
                  </button>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Recent Runs --%>
          <div>
            <h3 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">Recent Runs</h3>
            <%= if @runs == [] do %>
              <p class="text-base-content/40 text-sm">No runs yet. Run an action above to get started.</p>
            <% else %>
              <table class="w-full text-sm">
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
                  <%= for run <- @runs do %>
                    <tr class="border-b border-base-300/50 hover:bg-base-200/50">
                      <td class="py-3 pr-4 font-medium text-base-content"><%= run.action_type %></td>
                      <td class="py-3 pr-4 text-base-content/60 max-w-xs truncate"><%= run.project_path %></td>
                      <td class="py-3 pr-4">
                        <span class={run_status_class(run.status)}><%= run.status %></span>
                      </td>
                      <td class="py-3 pr-4 text-base-content/40 text-xs"><%= run.started_at %></td>
                      <td class="py-3 pr-4 text-base-content/60">
                        <%= format_duration(run.started_at, run.completed_at) %>
                      </td>
                      <td class="py-3">
                        <button phx-click="view_result" phx-value-id={run.id} class="btn btn-ghost btn-xs">
                          View
                        </button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            <% end %>
          </div>
        </div>
      </div>
    </div>

    <%!-- Run Action Modal --%>
    <%= if @show_modal and @selected_action do %>
      <div class="fixed inset-0 bg-black/50 flex items-center justify-center z-50" phx-click="close_modal">
        <div class="bg-base-200 rounded-xl border border-base-300 w-96" phx-click-stop>
          <div class="flex items-center justify-between px-4 py-3 border-b border-base-300">
            <h3 class="text-sm font-semibold text-base-content">Run: <%= @selected_action.name %></h3>
            <button phx-click="close_modal" class="btn btn-ghost btn-xs btn-circle">
              <.icon name="hero-x-mark" class="size-3" />
            </button>
          </div>
          <form phx-submit="run_action" class="p-4 space-y-3">
            <div>
              <label class="text-xs text-base-content/60 block mb-1">Project Path</label>
              <input
                type="text"
                name="project_path"
                value={@project_path}
                phx-change="update_path"
                placeholder="~/Developer/my-project"
                class="input input-bordered input-sm w-full bg-base-100"
                autofocus
              />
            </div>
            <p class="text-xs text-base-content/60"><%= @selected_action.description %></p>
            <div class="flex justify-end gap-2">
              <button type="button" phx-click="close_modal" class="btn btn-ghost btn-sm">Cancel</button>
              <button type="submit" class="btn btn-primary btn-sm">Run Action</button>
            </div>
          </form>
        </div>
      </div>
    <% end %>

    <%!-- Result Modal --%>
    <%= if @selected_run do %>
      <div class="fixed inset-0 bg-black/50 flex items-center justify-center z-50" phx-click="close_modal">
        <div class="bg-base-200 rounded-xl border border-base-300 w-2/3 max-h-2/3 flex flex-col" phx-click-stop>
          <div class="flex items-center justify-between px-4 py-3 border-b border-base-300">
            <h3 class="text-sm font-semibold text-base-content"><%= @selected_run.action_type %> Result</h3>
            <button phx-click="close_modal" class="btn btn-ghost btn-xs btn-circle">
              <.icon name="hero-x-mark" class="size-3" />
            </button>
          </div>
          <div class="p-4 overflow-auto">
            <%= if @selected_run.error do %>
              <p class="text-error text-sm"><%= @selected_run.error %></p>
            <% else %>
              <pre class="text-xs text-success whitespace-pre-wrap"><%= inspect(@selected_run.result, pretty: true) %></pre>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end
