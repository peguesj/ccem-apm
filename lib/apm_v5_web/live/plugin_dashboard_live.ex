defmodule ApmV5Web.PluginDashboardLive do
  @moduledoc """
  LiveView for /plugins (Engine plugins + MCP + Discovered + Plane PM)
  and /integrations (AG-UI, AgentLock, and any registered integration adapters).

  Both routes share this LiveView but target different active tabs:
    - /plugins       → :index         → active_tab: "mcp"
    - /integrations  → :integrations_tab → active_tab: "integrations"

  Interactive features:
    - Engine Plugins: action runner panel (select plugin → pick action → fill params → invoke → see result)
    - Integrations: event runner + live status check + connect/disconnect controls
    - Plane PM: Kanban board with issue detail drawer
  """

  use ApmV5Web, :live_view

  import ApmV5Web.Components.GettingStartedWizard

  require Logger

  @pubsub_topic "apm:plugins"
  @integrations_topic "apm:integrations"

  # ── Priority / state colour helpers ─────────────────────────────────────────

  defp priority_class("urgent"), do: "badge-error"
  defp priority_class("high"), do: "badge-warning"
  defp priority_class("medium"), do: "badge-info"
  defp priority_class(_), do: "badge-ghost"

  defp state_class("Backlog"), do: "badge-ghost"
  defp state_class("Todo"), do: "badge-info"
  defp state_class("In Progress"), do: "badge-warning"
  defp state_class("Done"), do: "badge-success"
  defp state_class("Cancelled"), do: "badge-error"
  defp state_class(_), do: "badge-ghost"

  defp protocol_class(:ag_ui), do: "badge-secondary"
  defp protocol_class(:custom), do: "badge-accent"
  defp protocol_class(:rest), do: "badge-info"
  defp protocol_class(:webhook), do: "badge-warning"
  defp protocol_class(_), do: "badge-ghost"

  defp status_class(:connected), do: "badge-success"
  defp status_class(:degraded), do: "badge-warning"
  defp status_class(:initializing), do: "badge-info"
  defp status_class(_), do: "badge-ghost"

  defp safe_status(val) when is_atom(val), do: val
  defp safe_status(val) when is_binary(val), do: val
  defp safe_status(%{status: s}), do: safe_status(s)
  defp safe_status(%{"status" => s}), do: safe_status(s)
  defp safe_status(_), do: :unknown

  # ── Empty state component ──────────────────────────────────────────────────

  attr :icon, :string, default: "hero-cube-transparent"
  attr :title, :string, required: true
  attr :hint, :string, default: nil
  attr :cta_label, :string, default: nil
  attr :cta_event, :string, default: nil
  attr :cta_href, :string, default: nil

  defp empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-12 px-6 text-center">
      <div class="size-12 rounded-full bg-base-300/60 flex items-center justify-center mb-3">
        <.icon name={@icon} class="size-6 text-base-content/40" />
      </div>
      <p class="text-sm font-medium text-base-content/70">{@title}</p>
      <p :if={@hint} class="text-xs text-base-content/40 mt-1 max-w-md">{@hint}</p>
      <button
        :if={@cta_label && @cta_event}
        phx-click={@cta_event}
        class="btn btn-xs btn-primary mt-4 gap-1"
      >
        <.icon name="hero-arrow-path" class="size-3.5" /> {@cta_label}
      </button>
      <a
        :if={@cta_label && @cta_href && !@cta_event}
        href={@cta_href}
        class="btn btn-xs btn-primary mt-4 gap-1"
      >
        <.icon name="hero-arrow-top-right-on-square" class="size-3.5" /> {@cta_label}
      </a>
    </div>
    """
  end

  # ── Mount ────────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(30_000, self(), :refresh)
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic)
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @integrations_topic)
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:cc_plugins")
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:plugin_repos")
    end

    {:ok,
     socket
     |> assign_data()
     |> assign(:sidebar_collapsed, false)
     |> assign(:inspector_open, false)
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()
     |> assign(
       active_tab: "mcp",
       current_path: "/plugins",
       selected_issue: nil,
       # Plugin action runner state
       selected_plugin: nil,
       selected_plugin_action: nil,
       plugin_action_params: "{}",
       plugin_action_result: nil,
       plugin_action_running: false,
       plugin_action_error: nil,
       # Integration event runner state
       selected_integration: nil,
       selected_integration_event: nil,
       integration_event_params: "{}",
       integration_event_result: nil,
       integration_event_running: false,
       integration_event_error: nil,
       integration_status_results: %{},
       # Claude Code plugin bridge
       cc_plugins: [],
       cc_plugins_summary: %{},
       # Plugin repositories
       plugin_repos: [],
       # Slug-based detail views
       selected_plugin_slug: nil,
       selected_integration_slug: nil,
       detail_plugin: nil
     )}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _uri, %{assigns: %{live_action: :plugin_show}} = socket) do
    alias ApmV5.Plugins.PluginRegistry

    case PluginRegistry.find_plugin_by_slug(slug) do
      {:ok, {mod, meta}} ->
        # If plugin has a dedicated LiveView, redirect to it
        live_mod =
          if Code.ensure_loaded?(mod) and function_exported?(mod, :plugin_live_module, 0),
            do: mod.plugin_live_module(),
            else: nil

        if live_mod && live_mod != __MODULE__ do
          # Derive path from the plugin's nav_items or fall back to standard /plugins/:slug
          nav_path =
            if function_exported?(mod, :nav_items, 0) do
              case mod.nav_items() do
                [{_, path, _} | _] -> path
                _ -> "/plugins/#{slug}"
              end
            else
              "/plugins/#{slug}"
            end

          {:noreply, push_navigate(socket, to: nav_path)}
        else
          # Render generic plugin detail page
          {:noreply,
           socket
           |> assign(
             active_tab: "plugin_detail",
             current_path: "/plugins/#{slug}",
             page_title: "Plugin: #{meta.name}",
             selected_plugin_slug: slug,
             detail_plugin: meta
           )}
        end

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(active_tab: "mcp", current_path: "/plugins/#{slug}", page_title: "Plugin: #{humanize(slug)}")
         |> assign(selected_plugin_slug: slug, detail_plugin: nil)
         |> put_flash(:error, "Plugin \"#{slug}\" not found")}
    end
  end

  def handle_params(%{"slug" => slug}, _uri, %{assigns: %{live_action: :integration_show}} = socket) do
    {:noreply,
     socket
     |> assign(active_tab: "integrations", current_path: "/integrations/#{slug}", page_title: "Integration: #{humanize(slug)}")
     |> assign(selected_integration_slug: slug)}
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :integrations_tab}} = socket) do
    {:noreply, assign(socket, active_tab: "integrations", current_path: "/integrations")}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, current_path: "/plugins")}
  end

  defp humanize(slug) do
    slug
    |> String.replace(["-", "_"], " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # ── Tab / navigation events ──────────────────────────────────────────────────

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    socket =
      socket
      |> assign(
        active_tab: tab,
        selected_issue: nil,
        selected_plugin: nil,
        selected_plugin_action: nil,
        plugin_action_result: nil,
        plugin_action_error: nil,
        selected_integration: nil,
        selected_integration_event: nil,
        integration_event_result: nil,
        integration_event_error: nil
      )

    socket = if tab == "plane", do: load_plane_issues(socket), else: socket

    {:noreply, socket}
  end

  @impl true
  def handle_event("rescan", _params, socket) do
    ApmV5.PluginScanner.rescan()
    Process.sleep(300)
    {:noreply, assign_data(socket)}
  end

  # ── Plane PM events ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_issue", %{"id" => id}, socket) do
    issue =
      (socket.assigns[:plane_issues] || [])
      |> Enum.find(&(to_string(&1.id) == id))

    {:noreply, assign(socket, selected_issue: issue)}
  end

  @impl true
  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign(socket, selected_issue: nil)}
  end

  @impl true
  def handle_event("reload_plane", _params, socket) do
    {:noreply, load_plane_issues(socket)}
  end

  # ── Plugin action runner events ──────────────────────────────────────────────

  @impl true
  def handle_event("select_plugin", %{"name" => name}, socket) do
    plugin =
      socket.assigns.registered_plugins
      |> Enum.find(&(&1.name == name))

    {:noreply,
     assign(socket,
       selected_plugin: plugin,
       selected_plugin_action: nil,
       plugin_action_params: "{}",
       plugin_action_result: nil,
       plugin_action_error: nil
     )}
  end

  @impl true
  def handle_event("close_plugin_panel", _params, socket) do
    {:noreply,
     assign(socket,
       selected_plugin: nil,
       selected_plugin_action: nil,
       plugin_action_result: nil,
       plugin_action_error: nil
     )}
  end

  @impl true
  def handle_event("select_plugin_action", %{"action" => action}, socket) do
    # Pre-fill param skeleton from endpoint descriptor
    params_skeleton =
      case socket.assigns.selected_plugin do
        nil ->
          "{}"

        plugin ->
          ep = Enum.find(plugin.endpoints, &(&1.action == action))

          case ep do
            %{params: params_map} when map_size(params_map) > 0 ->
              skeleton =
                params_map
                |> Enum.map(fn {k, v} -> ~s|  "#{k}": ""  #{inspect(v)}| end)
                |> Enum.join(",\n")

              "{\n#{skeleton}\n}"

            _ ->
              "{}"
          end
      end

    {:noreply,
     assign(socket,
       selected_plugin_action: action,
       plugin_action_params: params_skeleton,
       plugin_action_result: nil,
       plugin_action_error: nil
     )}
  end

  @impl true
  def handle_event("update_plugin_params", %{"params" => raw}, socket) do
    {:noreply, assign(socket, plugin_action_params: raw)}
  end

  @impl true
  def handle_event("run_plugin_action", _params, socket) do
    %{selected_plugin: plugin, selected_plugin_action: action, plugin_action_params: raw} =
      socket.assigns

    if is_nil(plugin) or is_nil(action) do
      {:noreply, assign(socket, plugin_action_error: "Select a plugin and action first.")}
    else
      params =
        case Jason.decode(raw) do
          {:ok, map} -> map
          {:error, _} -> %{}
        end

      socket = assign(socket, plugin_action_running: true, plugin_action_error: nil, plugin_action_result: nil)

      Task.start(fn ->
        result = ApmV5.Plugins.PluginRegistry.call_plugin_action(plugin.name, action, params)
        send(self(), {:plugin_action_done, result})
      end)

      {:noreply, socket}
    end
  end

  # ── Plugin detail action runner ──────────────────────────────────────────────

  @impl true
  def handle_event("detail_run_action", %{"plugin" => plugin_name, "action" => action}, socket) do
    socket = assign(socket, plugin_action_running: true, plugin_action_error: nil, plugin_action_result: nil)

    pid = self()
    Task.start(fn ->
      result = ApmV5.Plugins.PluginRegistry.call_plugin_action(plugin_name, action, %{})
      send(pid, {:plugin_action_done, result})
    end)

    {:noreply, socket}
  end

  # ── Integration event runner events ──────────────────────────────────────────

  @impl true
  def handle_event("select_integration", %{"name" => name}, socket) do
    integration =
      socket.assigns.integrations
      |> Enum.find(&(&1.name == name))

    {:noreply,
     assign(socket,
       selected_integration: integration,
       selected_integration_event: nil,
       integration_event_params: "{}",
       integration_event_result: nil,
       integration_event_error: nil
     )}
  end

  @impl true
  def handle_event("close_integration_panel", _params, socket) do
    {:noreply,
     assign(socket,
       selected_integration: nil,
       selected_integration_event: nil,
       integration_event_result: nil,
       integration_event_error: nil
     )}
  end

  @impl true
  def handle_event("select_integration_event", %{"event" => event}, socket) do
    params_skeleton =
      case socket.assigns.selected_integration do
        nil ->
          "{}"

        integration ->
          ep = Enum.find(integration.endpoints, &(&1.action == event))

          case ep do
            %{params: params_map} when is_map(params_map) and map_size(params_map) > 0 ->
              skeleton =
                params_map
                |> Enum.map(fn {k, v} -> ~s|  "#{k}": ""  #{inspect(v)}| end)
                |> Enum.join(",\n")

              "{\n#{skeleton}\n}"

            _ ->
              "{}"
          end
      end

    {:noreply,
     assign(socket,
       selected_integration_event: event,
       integration_event_params: params_skeleton,
       integration_event_result: nil,
       integration_event_error: nil
     )}
  end

  @impl true
  def handle_event("update_integration_params", %{"params" => raw}, socket) do
    {:noreply, assign(socket, integration_event_params: raw)}
  end

  @impl true
  def handle_event("run_integration_event", _params, socket) do
    %{
      selected_integration: integration,
      selected_integration_event: event,
      integration_event_params: raw
    } = socket.assigns

    if is_nil(integration) or is_nil(event) do
      {:noreply, assign(socket, integration_event_error: "Select an integration and event first.")}
    else
      params =
        case Jason.decode(raw) do
          {:ok, map} -> map
          {:error, _} -> %{}
        end

      socket = assign(socket, integration_event_running: true, integration_event_error: nil, integration_event_result: nil)

      name = integration.name

      Task.start(fn ->
        result = ApmV5.Integrations.IntegrationRegistry.call_integration_event(name, event, params)
        send(self(), {:integration_event_done, result})
      end)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("check_integration_status", %{"name" => name}, socket) do
    Task.start(fn ->
      status =
        case :ets.whereis(:integration_registry) do
          :undefined ->
            :disconnected

          _ ->
            case :ets.lookup(:integration_registry, name) do
              [{^name, {mod, _meta}}] ->
                try do
                  mod.status()
                rescue
                  _ -> :disconnected
                end

              [] ->
                :disconnected
            end
        end

      send(self(), {:integration_status_checked, name, status})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("reload_integrations", _params, socket) do
    ApmV5.Integrations.IntegrationRegistry.reload_defaults()
    Process.sleep(200)
    {:noreply, assign_integrations(socket)}
  end

  # ── Claude Code & Repository events ────────────────────────────────────────

  @impl true
  def handle_event("rescan_cc", _params, socket) do
    ApmV5.Plugins.ClaudeCodePluginBridge.rescan()
    Process.sleep(300)
    {:noreply, assign_cc_plugins(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_event("add_repo", %{"name" => name, "url" => url}, socket) do
    ApmV5.Plugins.PluginRepositoryStore.add_repo(%{"name" => name, "url" => url, "source" => "custom"})
    {:noreply, assign_repos(socket)}
  end

  @impl true
  def handle_event("delete_repo", %{"name" => name}, socket) do
    ApmV5.Plugins.PluginRepositoryStore.delete_repo(name)
    {:noreply, assign_repos(socket)}
  end

  # ── Info (async results + PubSub) ────────────────────────────────────────────

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_info({:plugin_registered, _meta}, socket) do
    {:noreply, assign_registered_plugins(socket)}
  end

  @impl true
  def handle_info({:integration_registered, _meta}, socket) do
    {:noreply, assign_integrations(socket)}
  end

  @impl true
  def handle_info({:plugin_action_done, result}, socket) do
    case result do
      {:ok, data} ->
        {:noreply,
         assign(socket,
           plugin_action_running: false,
           plugin_action_result: Jason.encode!(data, pretty: true),
           plugin_action_error: nil
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           plugin_action_running: false,
           plugin_action_result: nil,
           plugin_action_error: inspect(reason)
         )}
    end
  end

  @impl true
  def handle_info({:integration_event_done, result}, socket) do
    case result do
      {:ok, data} ->
        {:noreply,
         assign(socket,
           integration_event_running: false,
           integration_event_result: Jason.encode!(data, pretty: true),
           integration_event_error: nil
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           integration_event_running: false,
           integration_event_result: nil,
           integration_event_error: inspect(reason)
         )}
    end
  end

  @impl true
  def handle_info({:integration_status_checked, name, status}, socket) do
    results = Map.put(socket.assigns.integration_status_results, name, status)
    {:noreply, assign(socket, integration_status_results: results)}
  end

  @impl true
  def handle_info({:cc_plugins_updated, _count}, socket) do
    {:noreply, assign_cc_plugins(socket)}
  end

  @impl true
  def handle_info({:repo_added, _name}, socket) do
    {:noreply, assign_repos(socket)}
  end

  @impl true
  def handle_info({:repo_updated, _name}, socket) do
    {:noreply, assign_repos(socket)}
  end

  @impl true
  def handle_info({:repo_deleted, _name}, socket) do
    {:noreply, assign_repos(socket)}
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp assign_data(socket) do
    socket
    |> assign(
      mcp_servers: ApmV5.PluginScanner.get_mcp_servers(),
      plugins: ApmV5.PluginScanner.get_plugins(),
      page_title: "Plugins & Integrations"
    )
    |> assign_registered_plugins()
    |> assign_integrations()
    |> assign_cc_plugins()
    |> assign_repos()
  end

  defp assign_registered_plugins(socket) do
    assign(socket, registered_plugins: ApmV5.Plugins.PluginRegistry.list_plugins())
  end

  defp assign_integrations(socket) do
    integrations =
      if :ets.whereis(:integration_registry) != :undefined do
        ApmV5.Integrations.IntegrationRegistry.list_integrations()
      else
        []
      end

    assign(socket, integrations: integrations)
  end

  defp assign_cc_plugins(socket) do
    plugins = ApmV5.Plugins.ClaudeCodePluginBridge.list_cc_plugins()
    summary = ApmV5.Plugins.ClaudeCodePluginBridge.get_summary()
    assign(socket, cc_plugins: plugins, cc_plugins_summary: summary)
  end

  defp assign_repos(socket) do
    assign(socket, plugin_repos: ApmV5.Plugins.PluginRepositoryStore.list_repos())
  end

  defp marketplace_badge_class(marketplace) when is_binary(marketplace) do
    cond do
      String.contains?(marketplace, "anthropic") -> "badge-primary"
      String.contains?(marketplace, "official") -> "badge-secondary"
      String.contains?(marketplace, "community") -> "badge-info"
      true -> "badge-ghost"
    end
  end

  defp marketplace_badge_class(_), do: "badge-ghost"

  defp format_date(nil), do: ""

  defp format_date(date_string) when is_binary(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d")
      _ -> String.slice(date_string, 0, 10)
    end
  end

  defp format_date(_), do: ""

  defp load_plane_issues(socket) do
    case ApmV5.Plugins.PluginRegistry.call_plugin_action("plane", "board_state", %{}) do
      {:ok, %{board: board, total: total}} ->
        assign(socket,
          plane_board: board,
          plane_issues: Enum.flat_map(board, & &1.issues),
          plane_total: total,
          plane_error: nil
        )

      {:error, {:not_found, _}} ->
        assign(socket, plane_board: [], plane_issues: [], plane_total: 0, plane_error: "Plane plugin not registered")

      {:error, reason} ->
        assign(socket, plane_board: [], plane_issues: [], plane_total: 0, plane_error: inspect(reason))
    end
  end

  # ── Render ────────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> Map.put_new(:plane_board, [])
      |> Map.put_new(:plane_issues, [])
      |> Map.put_new(:plane_total, 0)
      |> Map.put_new(:plane_error, nil)
      |> Map.put_new(:registered_plugins, [])
      |> Map.put_new(:integrations, [])
      |> Map.put_new(:cc_plugins, [])
      |> Map.put_new(:cc_plugins_summary, %{})
      |> Map.put_new(:plugin_repos, [])

    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav current_path={@current_path} plugins={@plugins} integrations={@integrations} />
      </:sidebar>
      <:main>

      <div class="flex-1 flex flex-col overflow-hidden min-w-0">
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0 relative z-10">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">
              {cond do
                @active_tab == "plugin_detail" and @detail_plugin -> @detail_plugin.name
                @current_path == "/integrations" -> "Integrations"
                true -> "Plugins & MCP Servers"
              end}
            </h2>
            <div class="badge badge-sm badge-ghost">
              {if @current_path == "/integrations",
                do: "#{length(@integrations)} registered",
                else: "#{length(@mcp_servers)} MCP · #{length(@registered_plugins)} engine"}
            </div>
          </div>
          <div class="flex items-center gap-2">
            <button :if={@current_path == "/integrations"} phx-click="reload_integrations" class="btn btn-xs btn-ghost gap-1">
              <.icon name="hero-arrow-path" class="size-3.5" /> Reload
            </button>
            <button phx-click="rescan" class="btn btn-xs btn-ghost gap-1">
              <.icon name="hero-magnifying-glass" class="size-3.5" /> Rescan
            </button>
          </div>
        </header>

        <%!-- Tab bar (hidden on plugin detail pages) --%>
        <div :if={@active_tab != "plugin_detail"} class="border-b border-base-300 bg-base-200 px-4 flex gap-1 flex-shrink-0 overflow-x-auto">
          <button :if={@current_path != "/integrations"}
            phx-click="switch_tab" phx-value-tab="mcp"
            class={"tab tab-bordered tab-sm #{if @active_tab == "mcp", do: "tab-active", else: ""}"}>
            MCP ({length(@mcp_servers)})
          </button>
          <button :if={@current_path != "/integrations"}
            phx-click="switch_tab" phx-value-tab="discovered"
            class={"tab tab-bordered tab-sm #{if @active_tab == "discovered", do: "tab-active", else: ""}"}>
            Discovered ({length(@plugins)})
          </button>
          <button :if={@current_path != "/integrations"}
            phx-click="switch_tab" phx-value-tab="registered"
            class={"tab tab-bordered tab-sm #{if @active_tab == "registered", do: "tab-active", else: ""}"}>
            Engine Plugins ({length(@registered_plugins)})
          </button>
          <button :if={@current_path != "/integrations"}
            phx-click="switch_tab" phx-value-tab="plane"
            class={"tab tab-bordered tab-sm #{if @active_tab == "plane", do: "tab-active", else: ""}"}>
            Plane PM
          </button>
          <button :if={@current_path != "/integrations"}
            phx-click="switch_tab" phx-value-tab="claude_code"
            class={"tab tab-bordered tab-sm #{if @active_tab == "claude_code", do: "tab-active", else: ""}"}>
            Claude Code
            <span :if={Map.get(@cc_plugins_summary, :total_installed, 0) > 0} class="badge badge-xs badge-accent ml-1">
              {Map.get(@cc_plugins_summary, :total_installed, 0)}
            </span>
          </button>
          <button :if={@current_path != "/integrations"}
            phx-click="switch_tab" phx-value-tab="repositories"
            class={"tab tab-bordered tab-sm #{if @active_tab == "repositories", do: "tab-active", else: ""}"}>
            Repositories
            <span :if={length(@plugin_repos) > 0} class="badge badge-xs badge-ghost ml-1">
              {length(@plugin_repos)}
            </span>
          </button>
          <button :if={@current_path == "/integrations"}
            phx-click="switch_tab" phx-value-tab="integrations"
            class={"tab tab-bordered tab-sm #{if @active_tab == "integrations", do: "tab-active", else: ""}"}>
            Integrations ({length(@integrations)})
          </button>
        </div>

        <%!-- Content area --%>
        <div class="flex-1 overflow-hidden flex">
          <div class="flex-1 overflow-y-auto p-4 space-y-4">

            <%!-- Plugin Detail Page --%>
            <div :if={@active_tab == "plugin_detail" and @detail_plugin != nil}>
              <.plugin_detail_view plugin={@detail_plugin} selected_plugin_slug={@selected_plugin_slug}
                selected_plugin={@selected_plugin} selected_plugin_action={@selected_plugin_action}
                plugin_action_params={@plugin_action_params} plugin_action_result={@plugin_action_result}
                plugin_action_error={@plugin_action_error} plugin_action_running={@plugin_action_running} />
            </div>

            <%!-- MCP Servers --%>
            <div :if={@active_tab == "mcp"}>
              <div class="bg-base-200 rounded-lg p-4">
                <h2 class="text-sm font-semibold mb-3">MCP Servers ({length(@mcp_servers)})</h2>
                <.empty_state
                  :if={@mcp_servers == []}
                  icon="hero-server-stack"
                  title="No MCP servers configured"
                  hint="Add MCP servers to ~/.claude/settings.json under the mcpServers key. Reload the page after editing."
                  cta_label="Reload"
                  cta_event="refresh"
                />
                <div :if={@mcp_servers != []} class="overflow-x-auto">
                  <table class="table table-xs w-full">
                    <thead><tr><th>Name</th><th>Type</th><th>Command</th><th>Args</th></tr></thead>
                    <tbody>
                      <tr :for={server <- @mcp_servers}>
                        <td class="font-medium">{server.name}</td>
                        <td><span class="badge badge-xs badge-outline">{server.type}</span></td>
                        <td class="font-mono text-xs">{server.command}</td>
                        <td class="font-mono text-xs text-base-content/60">{Enum.join(server.args, " ")}</td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>

            <%!-- Discovered Plugins --%>
            <div :if={@active_tab == "discovered"}>
              <div class="bg-base-200 rounded-lg p-4">
                <h2 class="text-sm font-semibold mb-3">Discovered Plugins ({length(@plugins)})</h2>
                <.empty_state
                  :if={@plugins == []}
                  icon="hero-puzzle-piece"
                  title="No plugins discovered"
                  hint="Install Claude Code plugins into ~/.claude-plugin/ or ~/.claude/plugins/ and rescan."
                  cta_label="Rescan"
                  cta_event="refresh"
                />
                <div :if={@plugins != []} class="overflow-x-auto">
                  <table class="table table-xs w-full">
                    <thead><tr><th>Name</th><th>Version</th><th>Description</th></tr></thead>
                    <tbody>
                      <tr :for={plugin <- @plugins}>
                        <td class="font-medium">{plugin.name}</td>
                        <td><span class="badge badge-xs">{plugin.version}</span></td>
                        <td class="text-base-content/60">{plugin.description}</td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>

            <%!-- Engine Plugins (interactive) --%>
            <div :if={@active_tab == "registered"}>
              <div :if={@registered_plugins == []} class="bg-base-200 rounded-lg p-4">
                <.empty_state
                  icon="hero-squares-2x2"
                  title="No engine plugins registered"
                  hint="Engine plugins self-register with ApmV5.Plugins.PluginRegistry on boot. If the list is empty, the registry may not have started."
                />
              </div>
              <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
                <div
                  :for={plugin <- @registered_plugins}
                  phx-click="select_plugin"
                  phx-value-name={plugin.name}
                  class={[
                    "card card-compact shadow cursor-pointer transition-colors",
                    if(@selected_plugin && @selected_plugin.name == plugin.name,
                      do: "bg-primary/10 border border-primary/30",
                      else: "bg-base-200 hover:bg-base-100"
                    )
                  ]}
                >
                  <div class="card-body">
                    <div class="flex items-center justify-between">
                      <h3 class="font-semibold text-sm">{plugin.name}</h3>
                      <div class="flex gap-1 items-center">
                        <span :if={plugin.scope == :apm} class="badge badge-xs badge-accent">APM</span>
                        <span class="badge badge-xs badge-primary">v{plugin.version}</span>
                      </div>
                    </div>
                    <p class="text-xs text-base-content/60 line-clamp-2">{plugin.description}</p>
                    <div class="flex flex-wrap gap-1 mt-1">
                      <span :for={ep <- plugin.endpoints} class="badge badge-xs badge-outline">
                        {ep.action}
                      </span>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Integrations (interactive) --%>
            <div :if={@active_tab == "integrations"}>
              <div :if={@integrations == []} class="bg-base-200 rounded-lg p-4 text-xs text-base-content/40 text-center py-8">
                No integrations registered. Check IntegrationRegistry startup.
              </div>
              <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                <div
                  :for={integration <- @integrations}
                  phx-click="select_integration"
                  phx-value-name={integration.name}
                  class={[
                    "card card-compact shadow cursor-pointer transition-colors",
                    if(@selected_integration && @selected_integration.name == integration.name,
                      do: "bg-secondary/10 border border-secondary/30",
                      else: "bg-base-200 hover:bg-base-100"
                    )
                  ]}
                >
                  <div class="card-body">
                    <div class="flex items-center justify-between gap-2">
                      <h3 class="font-semibold text-sm">{integration.name}</h3>
                      <div class="flex gap-1 flex-wrap justify-end">
                        <span class={"badge badge-xs #{protocol_class(integration.protocol)}"}>
                          {integration.protocol}
                        </span>
                        <span class={"badge badge-xs #{status_class(safe_status(Map.get(@integration_status_results, integration.name, integration.status)))}"}>
                          {safe_status(Map.get(@integration_status_results, integration.name, integration.status))}
                        </span>
                        <span class="badge badge-xs">v{integration.version}</span>
                      </div>
                    </div>
                    <p class="text-xs text-base-content/60 line-clamp-2">{integration.description}</p>
                    <div class="flex items-center justify-between mt-1">
                      <div class="flex flex-wrap gap-1">
                        <span :for={ep <- integration.endpoints} class="badge badge-xs badge-outline">
                          {ep.action}
                        </span>
                      </div>
                      <button
                        phx-click="check_integration_status"
                        phx-value-name={integration.name}
                        phx-click-away-ignore
                        class="btn btn-xs btn-ghost shrink-0"
                        title="Refresh live status"
                      >
                        <.icon name="hero-signal" class="size-3" />
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Plane PM --%>
            <div :if={@active_tab == "plane"} class="space-y-4">
              <div class="flex items-center justify-between">
                <h2 class="text-sm font-semibold">Plane PM — CCEM Issues ({@plane_total})</h2>
                <button phx-click="reload_plane" class="btn btn-xs btn-ghost gap-1">
                  <.icon name="hero-arrow-path" class="size-3.5" /> Reload
                </button>
              </div>

              <div :if={@plane_error} class="alert alert-error text-xs">
                <.icon name="hero-exclamation-triangle" class="size-4" />
                <span>{@plane_error}</span>
              </div>

              <div :if={@plane_board == [] and is_nil(@plane_error)} class="text-xs text-base-content/40 py-8 text-center">
                Click Reload to fetch issues from Plane.
              </div>

              <div :if={@plane_board != []} class="flex gap-3 overflow-x-auto pb-2">
                <div :for={col <- @plane_board} class="flex-shrink-0 w-64 bg-base-200 rounded-lg p-3">
                  <div class="flex items-center justify-between mb-2">
                    <span class={"badge badge-sm #{state_class(col.state)}"}>{col.state}</span>
                    <span class="text-xs text-base-content/50">{col.count}</span>
                  </div>
                  <div class="space-y-2">
                    <button
                      :for={issue <- col.issues}
                      phx-click="select_issue"
                      phx-value-id={issue.id}
                      class="w-full text-left bg-base-100 rounded p-2 hover:bg-base-300 transition-colors"
                    >
                      <div class="flex items-start justify-between gap-1">
                        <span class="text-xs font-mono text-base-content/50">{issue.sequence_id}</span>
                        <span :if={issue.priority && issue.priority != "none"} class={"badge badge-xs #{priority_class(issue.priority)}"}>
                          {issue.priority}
                        </span>
                      </div>
                      <p class="text-xs mt-1 line-clamp-2">{issue.name}</p>
                    </button>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Claude Code Plugins --%>
            <div :if={@active_tab == "claude_code"} class="space-y-4">
              <div class="flex items-center justify-between">
                <h2 class="text-sm font-semibold">Claude Code Plugins</h2>
                <button phx-click="rescan_cc" class="btn btn-xs btn-ghost gap-1">
                  <.icon name="hero-arrow-path" class="size-3.5" /> Rescan
                </button>
              </div>

              <%!-- Summary stats --%>
              <div class="grid grid-cols-3 gap-3">
                <div class="bg-base-200 rounded-lg p-3 text-center">
                  <p class="text-xl font-bold">{Map.get(@cc_plugins_summary, :total_installed, 0)}</p>
                  <p class="text-xs text-base-content/50">Installed</p>
                </div>
                <div class="bg-base-200 rounded-lg p-3 text-center">
                  <p class="text-xl font-bold text-success">{Map.get(@cc_plugins_summary, :enabled_count, 0)}</p>
                  <p class="text-xs text-base-content/50">Enabled</p>
                </div>
                <div class="bg-base-200 rounded-lg p-3 text-center">
                  <p class="text-xl font-bold text-info">{Map.get(@cc_plugins_summary, :marketplace_count, 0)}</p>
                  <p class="text-xs text-base-content/50">Marketplaces</p>
                </div>
              </div>

              <.empty_state
                :if={@cc_plugins == []}
                icon="hero-puzzle-piece"
                title="No Claude Code plugins installed"
                hint="Install plugins into ~/.claude/plugins/ via the Claude Code marketplace, then rescan."
                cta_label="Rescan"
                cta_event="rescan_cc"
              />

              <%!-- Plugin card grid --%>
              <div :if={@cc_plugins != []} class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
                <div
                  :for={plugin <- @cc_plugins}
                  class="card card-compact bg-base-200 shadow"
                >
                  <div class="card-body">
                    <div class="flex items-center justify-between gap-2">
                      <h3 class="font-semibold text-sm truncate">{plugin.name}</h3>
                      <span class="badge badge-xs badge-primary shrink-0">v{plugin.version}</span>
                    </div>
                    <div class="flex flex-wrap gap-1 mt-1">
                      <span class={[
                        "badge badge-xs",
                        marketplace_badge_class(plugin.marketplace)
                      ]}>
                        {plugin.marketplace}
                      </span>
                      <span :if={plugin.enabled} class="badge badge-xs badge-success">enabled</span>
                      <span :if={!plugin.enabled} class="badge badge-xs badge-ghost">disabled</span>
                      <span :if={plugin.scope} class="badge badge-xs badge-outline">{plugin.scope}</span>
                    </div>
                    <p :if={plugin.description} class="text-xs text-base-content/60 line-clamp-2 mt-1">
                      {plugin.description}
                    </p>
                    <div class="flex items-center justify-between mt-2">
                      <span :if={plugin.installed_at} class="text-xs text-base-content/40">
                        {format_date(plugin.installed_at)}
                      </span>
                      <span :if={is_list(plugin.skills) and length(plugin.skills) > 0} class="badge badge-xs badge-info">
                        {length(plugin.skills)} skills
                      </span>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Repositories --%>
            <div :if={@active_tab == "repositories"} class="space-y-4">
              <h2 class="text-sm font-semibold">Plugin Repositories</h2>

              <div :if={@plugin_repos == []} class="text-xs text-base-content/40 py-8 text-center">
                No plugin repositories configured.
              </div>

              <%!-- Repo list --%>
              <div :if={@plugin_repos != []} class="space-y-2">
                <div :for={repo <- @plugin_repos} class="bg-base-200 rounded-lg p-3">
                  <div class="flex items-center justify-between">
                    <div class="flex items-center gap-2">
                      <h3 class="font-semibold text-sm">{repo.name}</h3>
                      <span :if={repo.builtin} class="badge badge-xs badge-accent">built-in</span>
                      <span :if={!repo.builtin} class="badge badge-xs badge-ghost">custom</span>
                    </div>
                    <button
                      :if={!repo.builtin}
                      phx-click="delete_repo"
                      phx-value-name={repo.name}
                      data-confirm={"Delete repository '#{repo.name}'?"}
                      class="btn btn-ghost btn-xs text-error"
                    >
                      <.icon name="hero-trash" class="size-3.5" />
                    </button>
                  </div>
                  <div class="mt-1 space-y-0.5">
                    <p :if={repo.url && repo.url != ""} class="text-xs text-base-content/50 font-mono truncate">{repo.url}</p>
                    <div class="flex gap-3 text-xs text-base-content/40">
                      <span>{repo.plugin_count} plugins</span>
                      <span :if={repo.last_synced}>synced: {format_date(repo.last_synced)}</span>
                    </div>
                  </div>
                </div>
              </div>

              <%!-- Add repository form --%>
              <div class="bg-base-200 rounded-lg p-4">
                <h3 class="text-xs font-semibold mb-3 text-base-content/60">Add Repository</h3>
                <form phx-submit="add_repo" class="flex gap-2 items-end">
                  <div class="flex-1">
                    <label class="label label-text text-xs">Name</label>
                    <input type="text" name="name" required placeholder="my-repo" class="input input-bordered input-xs w-full" />
                  </div>
                  <div class="flex-1">
                    <label class="label label-text text-xs">URL</label>
                    <input type="text" name="url" required placeholder="https://..." class="input input-bordered input-xs w-full" />
                  </div>
                  <button type="submit" class="btn btn-primary btn-xs">Add</button>
                </form>
              </div>
            </div>

          </div>

          <%!-- Plugin Action Runner Panel --%>
          <div :if={@active_tab == "registered" && @selected_plugin} class="w-80 xl:w-96 border-l border-base-300 bg-base-100 flex flex-col flex-shrink-0 overflow-hidden">
            <div class="flex items-center justify-between p-3 border-b border-base-300">
              <div>
                <div class="flex items-center gap-2">
                  <p class="font-semibold text-sm">{@selected_plugin.name}</p>
                  <span :if={@selected_plugin.scope == :apm} class="badge badge-xs badge-accent">APM</span>
                </div>
                <p class="text-xs text-base-content/50">v{@selected_plugin.version}</p>
              </div>
              <button phx-click="close_plugin_panel" class="btn btn-ghost btn-xs btn-circle">
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <div class="flex-1 overflow-y-auto p-3 space-y-3">
              <%!-- Action selector --%>
              <div>
                <p class="text-xs font-semibold mb-2 text-base-content/60">Actions</p>
                <div class="space-y-1">
                  <button
                    :for={ep <- @selected_plugin.endpoints}
                    phx-click="select_plugin_action"
                    phx-value-action={ep.action}
                    class={[
                      "w-full text-left px-2 py-1.5 rounded text-xs transition-colors",
                      if(@selected_plugin_action == ep.action,
                        do: "bg-primary text-primary-content",
                        else: "hover:bg-base-200"
                      )
                    ]}
                  >
                    <span class="font-mono font-medium">{ep.action}</span>
                    <span class="block text-xs opacity-60 truncate">{ep.description}</span>
                  </button>
                </div>
              </div>

              <%!-- Params input --%>
              <div :if={@selected_plugin_action}>
                <p class="text-xs font-semibold mb-1 text-base-content/60">Params (JSON)</p>
                <textarea
                  phx-blur="update_plugin_params"
                  phx-value-params={@plugin_action_params}
                  class="textarea textarea-bordered textarea-xs w-full font-mono text-xs h-24 resize-y"
                  spellcheck="false"
                >{@plugin_action_params}</textarea>

                <button
                  phx-click="run_plugin_action"
                  disabled={@plugin_action_running}
                  class="btn btn-primary btn-xs w-full mt-2 gap-1"
                >
                  <span :if={@plugin_action_running} class="loading loading-spinner loading-xs" />
                  <.icon :if={!@plugin_action_running} name="hero-play" class="size-3" />
                  {if @plugin_action_running, do: "Running…", else: "Run"}
                </button>
              </div>

              <%!-- Error --%>
              <div :if={@plugin_action_error} class="alert alert-error py-2 text-xs">
                <.icon name="hero-exclamation-circle" class="size-3.5" />
                <span class="break-all">{@plugin_action_error}</span>
              </div>

              <%!-- Result --%>
              <div :if={@plugin_action_result}>
                <div class="flex items-center justify-between mb-1">
                  <p class="text-xs font-semibold text-success">Result</p>
                </div>
                <pre class="bg-base-200 rounded p-2 text-xs font-mono overflow-x-auto whitespace-pre-wrap break-all max-h-64 overflow-y-auto"><%= @plugin_action_result %></pre>
              </div>
            </div>
          </div>

          <%!-- Integration Event Runner Panel --%>
          <div :if={@active_tab == "integrations" && @selected_integration} class="w-80 xl:w-96 border-l border-base-300 bg-base-100 flex flex-col flex-shrink-0 overflow-hidden">
            <div class="flex items-center justify-between p-3 border-b border-base-300">
              <div>
                <p class="font-semibold text-sm">{@selected_integration.name}</p>
                <div class="flex gap-1 mt-0.5">
                  <span class={"badge badge-xs #{protocol_class(@selected_integration.protocol)}"}>
                    {@selected_integration.protocol}
                  </span>
                  <span class={"badge badge-xs #{status_class(safe_status(Map.get(@integration_status_results, @selected_integration.name, @selected_integration.status)))}"}>
                    {safe_status(Map.get(@integration_status_results, @selected_integration.name, @selected_integration.status))}
                  </span>
                </div>
              </div>
              <div class="flex gap-1">
                <button
                  phx-click="check_integration_status"
                  phx-value-name={@selected_integration.name}
                  class="btn btn-ghost btn-xs btn-circle"
                  title="Refresh status"
                >
                  <.icon name="hero-signal" class="size-3.5" />
                </button>
                <button phx-click="close_integration_panel" class="btn btn-ghost btn-xs btn-circle">
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>
            </div>

            <div class="flex-1 overflow-y-auto p-3 space-y-3">
              <p class="text-xs text-base-content/60">{@selected_integration.description}</p>

              <%!-- Event selector --%>
              <div>
                <p class="text-xs font-semibold mb-2 text-base-content/60">Events</p>
                <div class="space-y-1">
                  <button
                    :for={ep <- @selected_integration.endpoints}
                    phx-click="select_integration_event"
                    phx-value-event={ep.action}
                    class={[
                      "w-full text-left px-2 py-1.5 rounded text-xs transition-colors",
                      if(@selected_integration_event == ep.action,
                        do: "bg-secondary text-secondary-content",
                        else: "hover:bg-base-200"
                      )
                    ]}
                  >
                    <span class="font-mono font-medium">{ep.action}</span>
                    <span class="block text-xs opacity-60 truncate">{ep.description}</span>
                  </button>
                </div>
              </div>

              <%!-- Params input --%>
              <div :if={@selected_integration_event}>
                <p class="text-xs font-semibold mb-1 text-base-content/60">Payload (JSON)</p>
                <textarea
                  phx-blur="update_integration_params"
                  phx-value-params={@integration_event_params}
                  class="textarea textarea-bordered textarea-xs w-full font-mono text-xs h-24 resize-y"
                  spellcheck="false"
                >{@integration_event_params}</textarea>

                <button
                  phx-click="run_integration_event"
                  disabled={@integration_event_running}
                  class="btn btn-secondary btn-xs w-full mt-2 gap-1"
                >
                  <span :if={@integration_event_running} class="loading loading-spinner loading-xs" />
                  <.icon :if={!@integration_event_running} name="hero-paper-airplane" class="size-3" />
                  {if @integration_event_running, do: "Sending…", else: "Send Event"}
                </button>
              </div>

              <%!-- Error --%>
              <div :if={@integration_event_error} class="alert alert-error py-2 text-xs">
                <.icon name="hero-exclamation-circle" class="size-3.5" />
                <span class="break-all">{@integration_event_error}</span>
              </div>

              <%!-- Result --%>
              <div :if={@integration_event_result}>
                <p class="text-xs font-semibold text-success mb-1">Response</p>
                <pre class="bg-base-200 rounded p-2 text-xs font-mono overflow-x-auto whitespace-pre-wrap break-all max-h-64 overflow-y-auto"><%= @integration_event_result %></pre>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Plane issue detail drawer --%>
      <div :if={@selected_issue} class="fixed inset-y-0 right-0 w-96 bg-base-100 shadow-2xl border-l border-base-300 z-50 flex flex-col">
        <div class="flex items-center justify-between p-4 border-b border-base-300">
          <span class="font-mono text-sm text-base-content/60">{@selected_issue.sequence_id}</span>
          <button phx-click="close_drawer" class="btn btn-ghost btn-xs btn-circle">
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <div class="flex-1 overflow-y-auto p-4 space-y-4">
          <h2 class="font-semibold text-sm">{@selected_issue.name}</h2>
          <div class="flex flex-wrap gap-2">
            <span class={"badge badge-sm #{state_class(@selected_issue.state_name)}"}>{@selected_issue.state_name}</span>
            <span :if={@selected_issue.priority && @selected_issue.priority != "none"} class={"badge badge-sm #{priority_class(@selected_issue.priority)}"}>
              {@selected_issue.priority}
            </span>
          </div>
          <div :if={@selected_issue.description && @selected_issue.description != ""}>
            <p class="text-xs font-semibold mb-1 text-base-content/60">Description</p>
            <p class="text-xs text-base-content/80 whitespace-pre-wrap">{@selected_issue.description}</p>
          </div>
          <div class="text-xs text-base-content/40 space-y-1">
            <p>Created: {@selected_issue.created_at}</p>
            <p>Updated: {@selected_issue.updated_at}</p>
            <p :if={@selected_issue.completed_at}>Completed: {@selected_issue.completed_at}</p>
          </div>
        </div>
      </div>
      <div :if={@selected_issue} phx-click="close_drawer" class="fixed inset-0 bg-black/30 z-40" />
    <.wizard page="welcome" dom_id="ccem-wizard-welcome-plugins" />
      </:main>
    </.page_layout>
    """
  end

  # ── Plugin Detail View Component ────────────────────────────────────────────

  attr :plugin, :map, required: true
  attr :selected_plugin_slug, :string, required: true
  attr :selected_plugin, :map, default: nil
  attr :selected_plugin_action, :string, default: nil
  attr :plugin_action_params, :string, default: "{}"
  attr :plugin_action_result, :any, default: nil
  attr :plugin_action_error, :any, default: nil
  attr :plugin_action_running, :boolean, default: false

  defp plugin_detail_view(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto space-y-6">
      <%!-- Back link --%>
      <div class="flex items-center gap-2">
        <.link navigate="/plugins" class="btn btn-ghost btn-xs gap-1">
          <.icon name="hero-arrow-left" class="size-3" /> All Plugins
        </.link>
      </div>

      <%!-- Plugin Header --%>
      <div class="bg-base-200 rounded-lg p-6">
        <div class="flex items-start justify-between">
          <div>
            <div class="flex items-center gap-3 mb-2">
              <h1 class="text-lg font-bold text-base-content">{@plugin.name}</h1>
              <span class="badge badge-sm badge-outline">{@plugin.version}</span>
              <span class={["badge badge-sm", scope_badge(@plugin[:scope])]}>
                {to_string(@plugin[:scope] || :apm)}
              </span>
            </div>
            <p class="text-sm text-base-content/60">{@plugin.description}</p>
          </div>
          <div class="text-right text-xs text-base-content/40">
            <p>Registered: {(@plugin[:registered_at] || "") |> String.slice(0, 10)}</p>
          </div>
        </div>
      </div>

      <%!-- Actions / Endpoints --%>
      <div :if={(@plugin.endpoints || []) != []} class="bg-base-200 rounded-lg p-4">
        <h2 class="text-sm font-semibold mb-3 flex items-center gap-2">
          <.icon name="hero-bolt" class="size-4" /> Actions
          <span class="badge badge-xs badge-ghost">{length(@plugin.endpoints)}</span>
        </h2>
        <div class="space-y-2">
          <%= for ep <- @plugin.endpoints do %>
            <div class="flex items-center justify-between bg-base-300/50 rounded px-3 py-2">
              <div class="flex-1">
                <span class="text-sm font-mono font-medium text-base-content/80">{ep.action}</span>
                <span :if={ep[:description]} class="text-xs text-base-content/40 ml-2">{ep.description}</span>
              </div>
              <button
                phx-click="detail_run_action"
                phx-value-plugin={@plugin.name}
                phx-value-action={ep.action}
                class="btn btn-xs btn-primary btn-outline"
              >
                Run
              </button>
            </div>
          <% end %>
        </div>

        <%!-- Action result display --%>
        <div :if={@plugin_action_result} class="mt-4 bg-success/10 border border-success/30 rounded-lg p-3">
          <h3 class="text-xs font-semibold text-success mb-1">Result</h3>
          <pre class="text-xs font-mono text-base-content/70 whitespace-pre-wrap overflow-x-auto max-h-60">{format_result(@plugin_action_result)}</pre>
        </div>
        <div :if={@plugin_action_error} class="mt-4 bg-error/10 border border-error/30 rounded-lg p-3">
          <h3 class="text-xs font-semibold text-error mb-1">Error</h3>
          <pre class="text-xs font-mono text-error/70 whitespace-pre-wrap">{inspect(@plugin_action_error)}</pre>
        </div>
      </div>

      <%!-- Integrations --%>
      <div :if={(@plugin[:integration_modules] || []) != []} class="bg-base-200 rounded-lg p-4">
        <h2 class="text-sm font-semibold mb-3 flex items-center gap-2">
          <.icon name="hero-link" class="size-4" /> Integrations
        </h2>
        <div class="flex flex-wrap gap-2">
          <span :for={int_mod <- @plugin.integration_modules} class="badge badge-sm badge-outline font-mono">
            {inspect(int_mod) |> String.replace("Elixir.", "")}
          </span>
        </div>
      </div>

      <%!-- Empty state for plugins with no actions --%>
      <div :if={(@plugin.endpoints || []) == []} class="bg-base-200 rounded-lg p-8 text-center">
        <.icon name="hero-puzzle-piece" class="size-12 text-base-content/20 mx-auto mb-3" />
        <p class="text-sm text-base-content/40">This plugin has no callable actions.</p>
        <p class="text-xs text-base-content/30 mt-1">It may provide widgets, integrations, or background services.</p>
      </div>
    </div>
    """
  end

  defp scope_badge(:apm), do: "badge-primary"
  defp scope_badge(:ccem), do: "badge-secondary"
  defp scope_badge(:claude_code), do: "badge-accent"
  defp scope_badge(:security), do: "badge-error"
  defp scope_badge(:memory), do: "badge-info"
  defp scope_badge(:orchestration), do: "badge-success"
  defp scope_badge(_), do: "badge-ghost"

  defp format_result(result) when is_map(result) or is_list(result) do
    Jason.encode!(result, pretty: true)
  rescue
    _ -> inspect(result, pretty: true)
  end
  defp format_result(result), do: inspect(result, pretty: true)
end
