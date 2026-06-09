defmodule ApmWeb.LvmStatusLive do
  @moduledoc """
  LiveView for LVM (Large Vision-Language Model) status at /integrations/lvm.

  Shows model capabilities, usage limits, and platform status.
  Subscribes to lvm:status and lvm:usage_changed PubSub topics for real-time updates.
  """

  use ApmWeb, :live_view

  alias Apm.ClaudeUsageStore
  alias Apm.Plugins.Lvm.ClaudePlatformLvmPlugin

  @lvm_topic "lvm:status"
  @usage_topic "lvm:usage_changed"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Apm.PubSub, @lvm_topic)
      Phoenix.PubSub.subscribe(Apm.PubSub, @usage_topic)
      :timer.send_interval(30_000, self(), :refresh)
    end

    socket =
      socket
      |> assign(:page_title, "LVM Status")
      |> assign(:current_path, "/integrations/lvm")
      |> assign(:active_tab, "models")
      |> assign(:active_skill_count, skill_count())
      |> load_data()

    {:ok,
     socket
     |> assign(:sidebar_collapsed, false)
     |> assign(:inspector_open, false)
     |> ApmWeb.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  @impl true
  def handle_params(%{"tab" => tab}, _uri, socket)
      when tab in ["models", "usage", "capabilities"] do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load_data(socket)}

  def handle_info({:lvm_capabilities_updated, _}, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_info({:lvm_limits_checked, _}, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_info({:effort_level_changed, _}, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav current_path="/integrations/lvm" skill_count={@active_skill_count} />
      </:sidebar>
      <:main>
        <div class="flex-1 flex flex-col overflow-hidden">
          <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0 relative z-10">
            <div class="flex items-center gap-3">
              <h2 class="text-sm font-semibold text-base-content">LVM Platform Status</h2>
              <div class="badge badge-sm badge-ghost">{length(@models)} models</div>
            </div>
            <div class="flex items-center gap-2">
              <span class="text-xs text-base-content/40">Auto-refresh 30s</span>
              <button phx-click="refresh" class="btn btn-xs btn-ghost gap-1">
                <.icon name="hero-arrow-path" class="size-3.5" /> Refresh
              </button>
            </div>
          </header>

          <main class="flex-1 overflow-y-auto p-4 space-y-4">
            <%!-- Tab navigation --%>
            <div role="tablist" class="tabs tabs-bordered">
              <a
                role="tab"
                class={"tab #{if @active_tab == "models", do: "tab-active"}"}
                phx-click="switch_tab"
                phx-value-tab="models"
              >
                Models ({length(@models)})
              </a>
              <a
                role="tab"
                class={"tab #{if @active_tab == "usage", do: "tab-active"}"}
                phx-click="switch_tab"
                phx-value-tab="usage"
              >
                Usage
              </a>
              <a
                role="tab"
                class={"tab #{if @active_tab == "capabilities", do: "tab-active"}"}
                phx-click="switch_tab"
                phx-value-tab="capabilities"
              >
                Dynamic Capabilities ({map_size(@dynamic_caps)})
              </a>
            </div>

            <%!-- Tab content --%>
            <div class="mt-4">
              <%= case @active_tab do %>
                <% "models" -> %>
                  <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <%= for model <- @models do %>
                      <div class="card bg-base-200 shadow">
                        <div class="card-body p-4">
                          <h3 class="card-title text-sm font-mono">{model.model}</h3>
                          <div class="grid grid-cols-2 gap-2 text-xs">
                            <div>
                              Context:
                              <span class="font-bold">
                                {format_tokens(Map.get(model, :context_window, 0))}
                              </span>
                            </div>
                            <div>
                              Max Output:
                              <span class="font-bold">
                                {format_tokens(Map.get(model, :max_output_tokens, 0))}
                              </span>
                            </div>
                            <div>Vision: {bool_badge(Map.get(model, :vision, false))}</div>
                            <div>Tool Use: {bool_badge(Map.get(model, :tool_use, false))}</div>
                            <div>
                              Computer Use: {bool_badge(Map.get(model, :computer_use, false))}
                            </div>
                            <div>
                              Thinking: {bool_badge(Map.get(model, :extended_thinking, false))}
                            </div>
                          </div>
                          <div class="mt-2">
                            <span class={"badge badge-sm #{tier_color(Map.get(model, :tier, "unknown"))}"}>
                              {Map.get(model, :tier, "unknown")}
                            </span>
                          </div>
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% "usage" -> %>
                  <div class="overflow-x-auto">
                    <table class="table table-sm">
                      <thead>
                        <tr>
                          <th>Project</th>
                          <th>Effort</th>
                          <th>Input Tokens</th>
                          <th>Output Tokens</th>
                          <th>Tool Calls</th>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for {project, data} <- @usage_summary do %>
                          <tr>
                            <td class="font-mono">{project}</td>
                            <td>
                              <span class={"badge badge-sm #{effort_color(Map.get(data, :effort_level, "low"))}"}>
                                {Map.get(data, :effort_level, "low")}
                              </span>
                            </td>
                            <td>{format_tokens(Map.get(data, :input_tokens, 0))}</td>
                            <td>{format_tokens(Map.get(data, :output_tokens, 0))}</td>
                            <td>{Map.get(data, :tool_calls, 0)}</td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                    <%= if map_size(@usage_summary) == 0 do %>
                      <div class="text-center text-sm opacity-50 py-8">No usage data recorded</div>
                    <% end %>
                  </div>
                <% "capabilities" -> %>
                  <div class="space-y-3">
                    <%= for {model, caps} <- @dynamic_caps do %>
                      <div class="card bg-base-200 shadow-sm">
                        <div class="card-body p-3">
                          <h4 class="font-mono text-sm">{model}</h4>
                          <pre class="text-xs bg-base-300 p-2 rounded overflow-x-auto"><%= Jason.encode!(caps, pretty: true) %></pre>
                        </div>
                      </div>
                    <% end %>
                    <%= if map_size(@dynamic_caps) == 0 do %>
                      <div class="text-center text-sm opacity-50 py-8">
                        No dynamic capabilities recorded. Capabilities are populated via POST /api/usage/record with model metadata.
                      </div>
                    <% end %>
                  </div>
                <% _ -> %>
                  <div class="text-center text-sm opacity-50 py-8">Unknown tab</div>
              <% end %>
            </div>
          </main>
        </div>
      </:main>
    </.page_layout>
    """
  end

  # -- Private -----------------------------------------------------------------

  defp load_data(socket) do
    models =
      ClaudePlatformLvmPlugin.known_models()
      |> Enum.map(fn {name, caps} -> Map.put(caps, :model, name) end)
      |> Enum.sort_by(& &1.model)

    summary = ClaudeUsageStore.get_summary()
    projects = Map.get(summary, :projects, %{})
    dynamic_caps = ClaudeUsageStore.get_all_model_capabilities()

    socket
    |> assign(:models, models)
    |> assign(:usage_summary, projects)
    |> assign(:dynamic_caps, dynamic_caps)
  end

  defp format_tokens(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp format_tokens(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_tokens(n), do: "#{n}"

  defp bool_badge(true),
    do: Phoenix.HTML.raw("<span class=\"badge badge-xs badge-success\">Yes</span>")

  defp bool_badge(_), do: Phoenix.HTML.raw("<span class=\"badge badge-xs badge-ghost\">No</span>")

  defp tier_color("flagship"), do: "badge-primary"
  defp tier_color("balanced"), do: "badge-info"
  defp tier_color("speed"), do: "badge-success"
  defp tier_color(_), do: "badge-ghost"

  defp effort_color("intensive"), do: "badge-error"
  defp effort_color("high"), do: "badge-warning"
  defp effort_color("medium"), do: "badge-info"
  defp effort_color(_), do: "badge-success"

  defp skill_count do
    try do
      Apm.SkillsRegistryStore.list_skills() |> length()
    rescue
      _ -> 0
    end
  end
end
