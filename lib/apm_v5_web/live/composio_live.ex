defmodule ApmV5Web.ComposioLive do
  @moduledoc """
  LiveView for the Composio plugin at `/plugins/composio`.

  Three tabs:
  - **Toolkits** — available Composio toolkit catalog
  - **Accounts** — connected auth accounts per integration
  - **MCP**      — registered MCP server endpoints

  Subscribes to `"composio:state"` PubSub for live state updates.
  """

  use ApmV5Web, :live_view

  require Logger

  alias ApmV5.Plugins.Composio.ComposioToolStore
  alias ApmV5.Plugins.Composio.ComposioAccountStore
  alias ApmV5.Plugins.Composio.ComposioMcpRegistry

  @pubsub_topic "composio:state"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic)
      send(self(), :load_data)
    end

    socket =
      socket
      |> assign(:page_title, "Composio")
      |> assign(:active_tab, "toolkits")
      |> assign(:toolkits, [])
      |> assign(:accounts, [])
      |> assign(:mcp_servers, [])
      |> assign(:loading, true)
      |> assign(:error, nil)
      |> assign(:notification_count, 0)
      |> assign(:skill_count, 0)
      |> assign(:sidebar_collapsed, false)
      |> assign(:inspector_open, false)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <ApmV5Web.Components.SidebarNav.sidebar_nav
          current_path="/plugins/composio"
          notification_count={@notification_count}
          skill_count={@skill_count}
        />
      </:sidebar>

      <:main>
        <div class="flex flex-col h-full">
          <%!-- Header --%>
          <div class="flex items-center justify-between px-6 py-4 border-b border-base-300">
            <div class="flex items-center gap-3">
              <.icon name="hero-bolt" class="w-5 h-5 text-accent" />
              <h1 class="text-lg font-semibold">Composio</h1>
              <.badge tone="accent">1000+ integrations</.badge>
            </div>
            <div class="flex items-center gap-2">
              <.badge :if={!@loading} tone="ok">connected</.badge>
              <.badge :if={@loading} tone="info">loading</.badge>
            </div>
          </div>

          <%!-- Tabs --%>
          <div class="flex gap-1 px-6 pt-3 border-b border-base-300">
            <%= for {id, label} <- [{"toolkits", "Toolkits"}, {"accounts", "Accounts"}, {"mcp", "MCP Servers"}] do %>
              <button
                phx-click="set_tab"
                phx-value-tab={id}
                class={[
                  "px-3 py-2 text-sm rounded-t border-b-2 transition-colors",
                  if(@active_tab == id,
                    do: "border-accent text-accent font-medium",
                    else: "border-transparent text-base-content/60 hover:text-base-content"
                  )
                ]}
              >
                <%= label %>
              </button>
            <% end %>
          </div>

          <%!-- Tab body --%>
          <div class="flex-1 overflow-auto px-6 py-4">
            <%= if @loading do %>
              <div class="flex items-center gap-2 text-sm text-base-content/60 py-8">
                <span class="loading loading-spinner loading-sm"></span>
                Loading Composio data…
              </div>
            <% else %>
              <%= case @active_tab do %>
                <% "toolkits" -> %>
                  <.toolkits_tab toolkits={@toolkits} />
                <% "accounts" -> %>
                  <.accounts_tab accounts={@accounts} />
                <% "mcp" -> %>
                  <.mcp_tab servers={@mcp_servers} />
              <% end %>
            <% end %>
          </div>
        </div>
      </:main>
    </.page_layout>
    """
  end

  # ── Tab Components ───────────────────────────────────────────────────────────

  attr :toolkits, :list, required: true

  defp toolkits_tab(assigns) do
    ~H"""
    <div class="space-y-2">
      <%= if @toolkits == [] do %>
        <p class="text-sm text-base-content/50 py-8 text-center">No toolkits cached yet. Analysis will populate this list.</p>
      <% else %>
        <div class="grid grid-cols-2 gap-3">
          <%= for tk <- @toolkits do %>
            <div class="border border-base-300 rounded-lg p-3">
              <div class="font-medium text-sm"><%= tk[:name] || tk["name"] || "Toolkit" %></div>
              <div class="text-xs text-base-content/60 mt-1"><%= tk[:description] || tk["description"] || "" %></div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :accounts, :list, required: true

  defp accounts_tab(assigns) do
    ~H"""
    <div class="space-y-2">
      <%= if @accounts == [] do %>
        <p class="text-sm text-base-content/50 py-8 text-center">No connected accounts. Connect an account via the Composio API.</p>
      <% else %>
        <%= for acct <- @accounts do %>
          <div class="flex items-center justify-between border border-base-300 rounded-lg p-3">
            <div>
              <div class="text-sm font-medium"><%= acct[:name] || acct["name"] || "Account" %></div>
              <div class="text-xs text-base-content/60"><%= acct[:app_name] || acct["appName"] || "" %></div>
            </div>
            <.badge tone={if acct[:status] == "ACTIVE" or acct["status"] == "ACTIVE", do: "ok", else: "neutral"}>
              <%= acct[:status] || acct["status"] || "unknown" %>
            </.badge>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :servers, :list, required: true

  defp mcp_tab(assigns) do
    ~H"""
    <div class="space-y-2">
      <%= if @servers == [] do %>
        <p class="text-sm text-base-content/50 py-8 text-center">No MCP servers registered. Register a server via the Composio API.</p>
      <% else %>
        <%= for srv <- @servers do %>
          <div class="border border-base-300 rounded-lg p-3 font-mono text-xs">
            <div class="font-medium text-sm font-sans"><%= srv[:name] || srv["name"] || "Server" %></div>
            <div class="text-base-content/60 mt-1 break-all"><%= srv[:url] || srv["url"] || "" %></div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  # ── Events ───────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  # ── Info ─────────────────────────────────────────────────────────────────────

  @impl true
  def handle_info(:load_data, socket) do
    toolkits = safe_call(fn -> ComposioToolStore.list_toolkits() end, [])
    accounts = safe_call(fn -> ComposioAccountStore.list_accounts("default") end, [])
    mcp_servers = safe_call(fn -> ComposioMcpRegistry.list_servers() end, [])

    socket =
      socket
      |> assign(:toolkits, toolkits)
      |> assign(:accounts, accounts)
      |> assign(:mcp_servers, mcp_servers)
      |> assign(:loading, false)

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Private ──────────────────────────────────────────────────────────────────

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end
end
