defmodule ApmV5Web.ClaudeCodeDiscoveryLive do
  @moduledoc """
  LiveView for the Claude Code plugin discovery page at /plugins/claude-code.

  Three tabs:
    - MCP Servers  — Discovered MCP server configurations from settings.json
    - Hooks        — Hook definitions (PreToolUse, PostToolUse, etc.)
    - Skills       — Installed skills scanned from ~/.claude/skills/
  """

  use ApmV5Web, :live_view

  alias ApmV5.Plugins.PluginRegistry

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Claude Code Discovery")
      |> assign(:active_tab, "mcp_servers")
      |> assign(:current_path, "/plugins/claude-code")
      |> assign(:active_skill_count, skill_count())
      |> load_discovery_data()

    {:ok, socket |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  @impl true
  def handle_params(%{"tab" => tab}, _uri, socket)
      when tab in ["mcp_servers", "hooks", "skills", "sessions"] do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_discovery_data(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <.sidebar_nav current_path="/plugins/claude-code" skill_count={@active_skill_count} />

      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0 relative z-10">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">Claude Code Discovery</h2>
            <div class="badge badge-sm badge-ghost"><%= length(@mcp_servers) %> MCP servers</div>
          </div>
          <div class="flex items-center gap-2">
            <button phx-click="refresh" class="btn btn-xs btn-ghost gap-1">
              <.icon name="hero-arrow-path" class="size-3.5" /> Refresh
            </button>
          </div>
        </header>

        <main class="flex-1 overflow-y-auto p-4 space-y-4">
          <%!-- Tab navigation --%>
          <div role="tablist" class="tabs tabs-bordered">
        <a role="tab" class={"tab #{if @active_tab == "mcp_servers", do: "tab-active"}"} phx-click="switch_tab" phx-value-tab="mcp_servers">
          MCP Servers (<%= length(@mcp_servers) %>)
        </a>
        <a role="tab" class={"tab #{if @active_tab == "hooks", do: "tab-active"}"} phx-click="switch_tab" phx-value-tab="hooks">
          Hooks (<%= length(@hooks) %>)
        </a>
        <a role="tab" class={"tab #{if @active_tab == "skills", do: "tab-active"}"} phx-click="switch_tab" phx-value-tab="skills">
          Skills (<%= length(@skills) %>)
        </a>
        <a role="tab" class={"tab #{if @active_tab == "sessions", do: "tab-active"}"} phx-click="switch_tab" phx-value-tab="sessions">
          Sessions (<%= length(@sessions) %>)
        </a>
      </div>

      <%!-- Tab content --%>
      <div class="mt-4">
        <%= case @active_tab do %>
          <% "mcp_servers" -> %>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
              <%= for server <- @mcp_servers do %>
                <div class="card bg-base-200 shadow">
                  <div class="card-body p-4">
                    <h3 class="card-title text-sm"><%= server.name %></h3>
                    <div class="text-xs opacity-70">
                      <p>Command: <code class="bg-base-300 px-1 rounded"><%= server.command %></code></p>
                      <p>Type: <span class="badge badge-xs badge-info"><%= server.type %></span></p>
                      <%= if length(server.env_keys) > 0 do %>
                        <p>Env vars: <%= Enum.join(server.env_keys, ", ") %></p>
                      <% end %>
                    </div>
                  </div>
                </div>
              <% end %>
              <%= if @mcp_servers == [] do %>
                <div class="col-span-full text-center text-sm opacity-50 py-8">No MCP servers discovered</div>
              <% end %>
            </div>

          <% "hooks" -> %>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr><th>Event</th><th>Type</th><th>Command</th><th>Timeout</th></tr>
                </thead>
                <tbody>
                  <%= for hook <- @hooks do %>
                    <tr>
                      <td><span class="badge badge-sm badge-outline"><%= hook.event %></span></td>
                      <td><%= hook.type %></td>
                      <td class="font-mono text-xs max-w-xs truncate"><%= hook.command %></td>
                      <td><%= hook.timeout %>ms</td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
              <%= if @hooks == [] do %>
                <div class="text-center text-sm opacity-50 py-8">No hooks discovered</div>
              <% end %>
            </div>

          <% "skills" -> %>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-3">
              <%= for skill <- @skills do %>
                <div class="card bg-base-200 shadow-sm">
                  <div class="card-body p-3">
                    <div class="flex items-center gap-2">
                      <span class={"badge badge-xs #{if skill.has_skill_md, do: "badge-success", else: "badge-warning"}"}></span>
                      <span class="font-mono text-sm"><%= skill.name %></span>
                    </div>
                  </div>
                </div>
              <% end %>
              <%= if @skills == [] do %>
                <div class="col-span-full text-center text-sm opacity-50 py-8">No skills discovered</div>
              <% end %>
            </div>

          <% "sessions" -> %>
            <div class="space-y-3">
              <%= for session <- @sessions do %>
                <div class="card bg-base-200 shadow-sm">
                  <div class="card-body p-3">
                    <div class="text-sm font-mono"><%= Map.get(session, "file", "unknown") %></div>
                    <div class="text-xs opacity-70">
                      Project: <%= Map.get(session, "project_name", "unknown") %> |
                      Started: <%= Map.get(session, "start_time", "unknown") %>
                    </div>
                  </div>
                </div>
              <% end %>
              <%= if @sessions == [] do %>
                <div class="text-center text-sm opacity-50 py-8">No active sessions</div>
              <% end %>
            </div>

          <% _ -> %>
            <div class="text-center text-sm opacity-50 py-8">Unknown tab</div>
        <% end %>
          </div>
        </main>
      </div>
    </div>
    """
  end

  # -- Private -----------------------------------------------------------------

  defp load_discovery_data(socket) do
    mcp = call_plugin("discover_mcp_servers")
    hooks = call_plugin("discover_hooks")
    skills = call_plugin("discover_skills")
    sessions = call_plugin("session_info")

    socket
    |> assign(:mcp_servers, Map.get(mcp, :mcp_servers, []))
    |> assign(:hooks, Map.get(hooks, :hooks, []))
    |> assign(:skills, Map.get(skills, :skills, []))
    |> assign(:sessions, Map.get(sessions, :sessions, []))
  end

  defp call_plugin(action) do
    case PluginRegistry.call_plugin_action("claude_code", action, %{}) do
      {:ok, result} -> result
      {:error, _} -> %{}
    end
  end

  defp skill_count do
    try do
      ApmV5.SkillsRegistryStore.list_skills() |> length()
    rescue
      _ -> 0
    end
  end
end
