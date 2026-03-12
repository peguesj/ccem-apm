defmodule ApmV5Web.UatLive do
  @moduledoc """
  LiveView for the UAT (User Acceptance Test) dashboard at /uat.

  Provides a real-time view of UAT test execution, results filtering by category,
  and controls for running/exporting/clearing test results. Subscribes to the
  "apm:uat" PubSub topic for live result streaming.
  """

  use ApmV5Web, :live_view

  import ApmV5Web.Components.GettingStartedShowcase

  alias ApmV5.UatRunner

  @categories [:all, :api, :liveview, :genserver, :pubsub, :channel, :ag_ui, :integration]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:uat")
    end

    {:ok,
     socket
     |> assign(:page_title, "UAT Dashboard")
     |> assign(:results, [])
     |> assign(:all_results, [])
     |> assign(:summary, default_summary())
     |> assign(:active_tab, :all)
     |> assign(:show_showcase, false)}
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("run_all", _params, socket) do
    case UatRunner.run_all() do
      {:ok, _run_id} ->
        {:noreply, assign(socket, :summary, %{socket.assigns.summary | status: :running})}

      {:error, :already_running} ->
        {:noreply, put_flash(socket, :error, "Tests already running")}
    end
  end

  def handle_event("filter", %{"category" => cat}, socket) do
    category = String.to_existing_atom(cat)

    filtered =
      if category == :all,
        do: socket.assigns.all_results,
        else: Enum.filter(socket.assigns.all_results, &(&1[:category] == category))

    {:noreply, assign(socket, active_tab: category, results: filtered)}
  end

  def handle_event("run_category", _params, socket) do
    tab = socket.assigns.active_tab

    if tab != :all do
      UatRunner.run_category(tab)
    end

    {:noreply, socket}
  end

  def handle_event("clear", _params, socket) do
    UatRunner.clear_results()
    {:noreply, assign(socket, results: [], all_results: [], summary: default_summary())}
  end

  def handle_event("export_json", _params, socket) do
    json =
      Jason.encode!(
        %{results: socket.assigns.all_results, summary: socket.assigns.summary},
        pretty: true
      )

    {:noreply,
     push_event(socket, "download", %{
       content: json,
       filename: "uat-results-#{DateTime.utc_now() |> DateTime.to_unix()}.json"
     })}
  end

  # Showcase events
  def handle_event("showcase:dismiss", _params, socket) do
    {:noreply, assign(socket, :show_showcase, false)}
  end

  def handle_event("showcase:show", _params, socket) do
    socket =
      socket
      |> assign(:show_showcase, true)
      |> push_event("showcase:reshow", %{})

    {:noreply, socket}
  end

  # --- PubSub Handlers ---

  @impl true
  def handle_info({:uat_result, result}, socket) do
    all_results = socket.assigns.all_results ++ [result]
    results = filter_results(all_results, socket.assigns.active_tab)
    summary = UatRunner.get_summary()
    {:noreply, assign(socket, all_results: all_results, results: results, summary: summary)}
  end

  def handle_info({:uat_complete, summary}, socket) do
    {:noreply, assign(socket, summary: summary)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
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

  # --- Private Helpers ---

  defp default_summary do
    %{total: 0, passed: 0, failed: 0, skipped: 0, duration_ms: 0, status: :idle, run_id: nil}
  end

  defp filter_results(all_results, :all), do: all_results

  defp filter_results(all_results, category) do
    Enum.filter(all_results, &(&1[:category] == category))
  end

  defp status_badge_class(status) when status in [:pass, :passed], do: "badge badge-success"
  defp status_badge_class(status) when status in [:fail, :failed], do: "badge badge-error"
  defp status_badge_class(status) when status in [:skip, :skipped], do: "badge badge-warning"
  defp status_badge_class(_), do: "badge badge-ghost"

  defp category_label(:api), do: "API"
  defp category_label(:liveview), do: "LiveView"
  defp category_label(:genserver), do: "GenServer"
  defp category_label(:pubsub), do: "PubSub"
  defp category_label(:channel), do: "Channel"
  defp category_label(:ag_ui), do: "AG-UI"
  defp category_label(:integration), do: "Integration"
  defp category_label(:all), do: "All"
  defp category_label(other), do: to_string(other)

  defp truncate(nil, _), do: ""

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "..."
    else
      str
    end
  end

  defp truncate(other, max), do: truncate(to_string(other), max)

  defp progress_percentage(%{total: 0}), do: 0

  defp progress_percentage(%{total: total, passed: passed, failed: failed, skipped: skipped}) do
    completed = passed + failed + skipped
    round(completed / total * 100)
  end

  defp progress_percentage(_), do: 0

  # --- Render ---

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :categories, @categories)

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
          <.nav_item icon="hero-inbox-arrow-down" label="Intake" active={false} href="/intake" />
          <.nav_item icon="hero-magnifying-glass" label="Project Scanner" active={false} href="/scanner" />
          <.nav_item icon="hero-bolt" label="Actions" active={false} href="/actions" />
          <.nav_item icon="hero-sparkles" label="Skills" active={false} href="/skills" />
          <.nav_item icon="hero-arrow-path" label="Ralph" active={false} href="/ralph" />
          <.nav_item icon="hero-signal" label="Ports" active={false} href="/ports" />
          <.nav_item icon="hero-chart-bar" label="Analytics" active={false} href="/analytics" />
          <.nav_item icon="hero-heart" label="Health" active={false} href="/health" />
          <.nav_item icon="hero-beaker" label="UAT" active={true} href="/uat" />
          <.nav_item icon="hero-chat-bubble-left-right" label="Conversations" active={false} href="/conversations" />
          <.nav_item icon="hero-puzzle-piece" label="Plugins" active={false} href="/plugins" />
          <.nav_item icon="hero-book-open" label="Docs" active={false} href="/docs" />
        </nav>
      </aside>

      <%!-- Main content --%>
      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Header --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">UAT Dashboard</h2>
            <div class="badge badge-sm badge-ghost"><%= length(@all_results) %> results</div>
          </div>
          <div class="flex gap-2">
            <button
              phx-click="run_all"
              disabled={@summary.status == :running}
              class={["btn btn-xs btn-primary gap-1", @summary.status == :running && "btn-disabled"]}
            >
              <.icon name="hero-play" class="size-3" />
              Run All
            </button>
            <button
              phx-click="run_category"
              disabled={@active_tab == :all}
              class={["btn btn-xs btn-ghost gap-1", @active_tab == :all && "btn-disabled"]}
            >
              <.icon name="hero-play" class="size-3" />
              Run Category
            </button>
            <button phx-click="export_json" class="btn btn-xs btn-ghost gap-1">
              <.icon name="hero-arrow-down-tray" class="size-3" />
              Export JSON
            </button>
            <button phx-click="clear" class="btn btn-xs btn-ghost gap-1">
              <.icon name="hero-trash" class="size-3" />
              Clear
            </button>
          </div>
        </header>

        <%!-- Body --%>
        <div class="flex-1 overflow-auto p-4 space-y-4">
          <%!-- Summary bar --%>
          <div class="bg-base-200 rounded-lg p-4">
            <div class="flex items-center gap-4 flex-wrap">
              <div class="flex items-center gap-2">
                <span class="text-xs text-base-content/50">Total</span>
                <span class="badge badge-sm"><%= @summary.total %></span>
              </div>
              <div class="flex items-center gap-2">
                <span class="text-xs text-base-content/50">Passed</span>
                <span class="badge badge-sm badge-success"><%= @summary.passed %></span>
              </div>
              <div class="flex items-center gap-2">
                <span class="text-xs text-base-content/50">Failed</span>
                <span class="badge badge-sm badge-error"><%= @summary.failed %></span>
              </div>
              <div class="flex items-center gap-2">
                <span class="text-xs text-base-content/50">Skipped</span>
                <span class="badge badge-sm badge-warning"><%= @summary.skipped %></span>
              </div>
              <div :if={@summary[:duration_ms] && @summary.duration_ms > 0} class="flex items-center gap-2 ml-auto">
                <span class="text-xs text-base-content/40"><%= @summary.duration_ms %>ms</span>
              </div>
            </div>
            <%!-- Progress bar — visible only when running --%>
            <div :if={@summary.status == :running} class="mt-3">
              <div class="w-full bg-base-300 rounded-full h-2">
                <div
                  class="bg-primary h-2 rounded-full transition-all duration-300"
                  style={"width: #{progress_percentage(@summary)}%"}
                >
                </div>
              </div>
              <div class="text-xs text-base-content/40 mt-1">
                Running... <%= progress_percentage(@summary) %>% complete
              </div>
            </div>
          </div>

          <%!-- Category tabs --%>
          <div class="flex gap-1 flex-wrap">
            <%= for cat <- @categories do %>
              <button
                phx-click="filter"
                phx-value-category={cat}
                class={["btn btn-xs", if(@active_tab == cat, do: "btn-primary", else: "btn-ghost")]}
              >
                <%= category_label(cat) %>
              </button>
            <% end %>
          </div>

          <%!-- Results table --%>
          <div class="bg-base-200 rounded-lg overflow-hidden">
            <div class="overflow-auto">
              <table class="w-full text-sm">
                <thead>
                  <tr class="text-left text-base-content/50 border-b border-base-300 bg-base-300/30">
                    <th class="pb-2 pt-2 px-4">Status</th>
                    <th class="pb-2 pt-2 px-4">ID</th>
                    <th class="pb-2 pt-2 px-4">Name</th>
                    <th class="pb-2 pt-2 px-4">Category</th>
                    <th class="pb-2 pt-2 px-4">Duration</th>
                    <th class="pb-2 pt-2 px-4">Message</th>
                  </tr>
                </thead>
                <tbody>
                  <%= if @results == [] do %>
                    <tr>
                      <td colspan="6" class="py-12 text-center text-base-content/40">
                        <div class="flex flex-col items-center gap-2">
                          <.icon name="hero-beaker" class="size-8 opacity-30" />
                          <span>No test results yet. Click <strong>Run All</strong> to start.</span>
                        </div>
                      </td>
                    </tr>
                  <% else %>
                    <%= for result <- @results do %>
                      <tr class="border-b border-base-300/50 hover:bg-base-300/30">
                        <td class="py-2 px-4">
                          <span class={status_badge_class(result[:status])}><%= result[:status] %></span>
                        </td>
                        <td class="py-2 px-4 font-mono text-xs text-base-content/60">
                          <%= String.slice(to_string(result[:id] || ""), 0, 8) %>
                        </td>
                        <td class="py-2 px-4 text-base-content font-medium">
                          <%= result[:name] || "-" %>
                        </td>
                        <td class="py-2 px-4">
                          <span class="badge badge-xs badge-outline"><%= category_label(result[:category]) %></span>
                        </td>
                        <td class="py-2 px-4 text-xs text-base-content/60 font-mono">
                          <%= result[:duration_ms] || 0 %>ms
                        </td>
                        <td class="py-2 px-4 text-xs text-base-content/50 max-w-xs truncate" title={result[:message]}>
                          <%= truncate(result[:message], 80) %>
                        </td>
                      </tr>
                    <% end %>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>

      <%!-- Getting Started Showcase --%>
      <.showcase show={@show_showcase} />
    </div>
    """
  end
end
