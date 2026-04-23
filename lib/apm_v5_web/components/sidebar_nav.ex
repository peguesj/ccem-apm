defmodule ApmV5Web.Components.SidebarNav do
  @moduledoc """
  Shared sidebar navigation component for all LiveViews.

  Organized into a 5-section taxonomy per the v8.9.0 platform refactor:

  1. **CORE** — main monitoring surfaces (Dashboard, Showcase, Projects,
     Formations, Sessions, Conversations, Timeline, Notifications, Health)
  2. **AUTHORIZATION** — AgentLock subsystem (Authorization, Routing)
  3. **PLUGINS** — dynamic section populated from `PluginRegistry.list_plugins/0`
     (Plugins index, per-plugin entries, Library)
  4. **INTEGRATIONS** — dynamic section populated from
     `IntegrationRegistry.list_integrations/0` (Integrations index, AG-UI, Ralph)
  5. **SYSTEM** — config, analytics, developer tools (Skills, Usage, Analytics,
     Actions, Background Tasks, Ports, Project Scanner, UAT, Docs)

  The `plugins` and `integrations` attrs are populated via
  `assign_sidebar_nav_data/1`, which safely polls the registries with
  try/rescue guards so sidebar rendering never fails if a registry GenServer
  is unavailable.
  """
  use Phoenix.Component
  import ApmV5Web.CoreComponents, only: [icon: 1]

  attr :current_path, :string, required: true
  attr :notification_count, :integer, default: 0
  attr :skill_count, :integer, default: 0
  attr :plugins, :list, default: []
  attr :integrations, :list, default: []

  def sidebar_nav(assigns) do
    # Always populate plugins/integrations from registries if not provided
    plugins = if assigns[:plugins] in [nil, []], do: safe_list_plugins(), else: assigns[:plugins]
    integrations = if assigns[:integrations] in [nil, []], do: safe_list_integrations(), else: assigns[:integrations]

    assigns =
      assigns
      |> assign(:plugins, plugins)
      |> assign(:integrations, integrations)
      |> assign(:version, version())

    ~H"""
    <aside id="apm-sidebar" class="w-52 bg-base-200 border-r border-base-300 flex flex-col flex-shrink-0">
      <div class="p-3 border-b border-base-300">
        <div class="sidebar-brand flex items-center justify-between gap-2">
          <div class="flex items-center gap-2 min-w-0">
            <div class="w-2 h-2 rounded-full bg-success animate-pulse flex-shrink-0"></div>
            <span class="font-mono font-bold text-sm text-base-content sidebar-label truncate">CCEM APM</span>
          </div>
          <button
            onclick="window.apmSidebar.toggle()"
            class="btn btn-ghost btn-xs p-0.5 flex-shrink-0 text-base-content/40 hover:text-base-content"
            title="Toggle sidebar"
          >
            <.icon name="hero-chevron-left" class="size-3 sidebar-arrow-collapse" />
            <.icon name="hero-chevron-right" class="size-3 sidebar-arrow-expand" />
          </button>
        </div>
        <div class="text-xs text-base-content/40 mt-0.5 sidebar-label sidebar-version">v{@version}</div>
      </div>
      <nav class="flex-1 p-2 space-y-0.5 overflow-y-auto" aria-label="Main navigation">
        <.core_nav
          current_path={@current_path}
          notification_count={@notification_count}
        />
        <.auth_nav current_path={@current_path} />
        <.plugins_nav current_path={@current_path} plugins={@plugins} />
        <.integrations_nav current_path={@current_path} integrations={@integrations} />
        <.system_nav current_path={@current_path} skill_count={@skill_count} />
      </nav>
    </aside>
    """
  end

  # ── Section: CORE ────────────────────────────────────────────────────────────
  attr :current_path, :string, required: true
  attr :notification_count, :integer, default: 0

  defp core_nav(assigns) do
    ~H"""
    <.section_header label="Core" />
    <.nav_item icon="hero-squares-2x2" label="Dashboard" href="/" current_path={@current_path} />
    <.nav_item icon="hero-presentation-chart-bar" label="Showcase" href="/showcase" current_path={@current_path} />
    <.nav_item icon="hero-globe-alt" label="All Projects" href="/apm-all" current_path={@current_path} />
    <.nav_item icon="hero-rectangle-group" label="Formations" href="/formation" current_path={@current_path} />
    <.nav_item icon="hero-computer-desktop" label="Sessions" href="/sessions" current_path={@current_path} />
    <.nav_item icon="hero-chat-bubble-left-right" label="Conversations" href="/conversations" current_path={@current_path} />
    <.nav_item icon="hero-clock" label="Timeline" href="/timeline" current_path={@current_path} />
    <.nav_item icon="hero-bell" label="Notifications" href="/notifications" current_path={@current_path} badge={@notification_count} />
    <.nav_item icon="hero-arrow-path-rounded-square" label="Orchestration" href="/orchestration" current_path={@current_path} />
    <.nav_item icon="hero-light-bulb" label="Memory" href="/memory" current_path={@current_path} />
    <.nav_item icon="hero-heart" label="Health" href="/health" current_path={@current_path} />
    """
  end

  # ── Section: AUTHORIZATION ───────────────────────────────────────────────────
  attr :current_path, :string, required: true

  defp auth_nav(assigns) do
    ~H"""
    <.section_header label="Authorization" />
    <.nav_item icon="hero-shield-check" label="Authorization" href="/authorization" current_path={@current_path} />
    <.nav_item icon="hero-map" label="Routing" href="/routing" current_path={@current_path} />
    """
  end

  # ── Section: PLUGINS (dynamic, collapsible sub-items) ─────────────────────────
  attr :current_path, :string, required: true
  attr :plugins, :list, required: true

  defp plugins_nav(assigns) do
    # Determine if any plugin sub-page is active (to auto-expand)
    plugins_expanded =
      String.starts_with?(assigns.current_path || "", "/plugins") or
        String.starts_with?(assigns.current_path || "", "/library")

    assigns = assign(assigns, :plugins_expanded, plugins_expanded)

    ~H"""
    <.section_header label="Plugins" />
    <.nav_item icon="hero-puzzle-piece" label="Plugins" href="/plugins" current_path={@current_path}
      badge={length(@plugins)} />
    <div :if={@plugins_expanded or length(@plugins) <= 8} class="pl-3 border-l border-base-300 ml-5 space-y-0.5">
      <%= for plugin <- @plugins do %>
        <% name = plugin[:name] || plugin["name"] || "plugin" %>
        <% scope = plugin[:scope] || plugin["scope"] %>
        <.nav_sub_item
          icon={plugin_scope_icon(scope)}
          label={humanize_name(name)}
          href={plugin_href(plugin)}
          current_path={@current_path}
          badge_label={if scope == :apm, do: "APM", else: nil}
        />
      <% end %>
    </div>
    <.nav_item icon="hero-book-open" label="Library" href="/library" current_path={@current_path} />
    """
  end

  # ── Section: INTEGRATIONS (dynamic, collapsible sub-items) ────────────────────
  attr :current_path, :string, required: true
  attr :integrations, :list, required: true

  defp integrations_nav(assigns) do
    integrations_expanded =
      String.starts_with?(assigns.current_path || "", "/integrations") or
        String.starts_with?(assigns.current_path || "", "/ag-ui") or
        String.starts_with?(assigns.current_path || "", "/ralph")

    assigns = assign(assigns, :integrations_expanded, integrations_expanded)

    ~H"""
    <.section_header label="Integrations" />
    <.nav_item icon="hero-circle-stack" label="Integrations" href="/integrations" current_path={@current_path}
      badge={length(@integrations)} />
    <div :if={@integrations_expanded or length(@integrations) <= 8} class="pl-3 border-l border-base-300 ml-5 space-y-0.5">
      <.nav_sub_item icon="hero-cpu-chip" label="AG-UI" href="/ag-ui" current_path={@current_path} />
      <.nav_sub_item icon="hero-arrow-path" label="Ralph" href="/ralph" current_path={@current_path} />
      <.nav_sub_item
        :for={integ <- filtered_integrations(@integrations)}
        icon="hero-circle-stack"
        label={humanize_name(integ[:name] || integ["name"] || "integration")}
        href={integration_href(integ)}
        current_path={@current_path}
      />
    </div>
    """
  end

  # ── Section: SYSTEM ──────────────────────────────────────────────────────────
  attr :current_path, :string, required: true
  attr :skill_count, :integer, default: 0

  defp system_nav(assigns) do
    ~H"""
    <.section_header label="System" />
    <.nav_item icon="hero-sparkles" label="Skills" href="/skills" current_path={@current_path} badge={@skill_count} />
    <.nav_item icon="hero-cpu-chip" label="Usage" href="/usage" current_path={@current_path} />
    <.nav_item icon="hero-chart-bar" label="Analytics" href="/analytics" current_path={@current_path} />
    <.nav_item icon="hero-bolt" label="Actions" href="/actions" current_path={@current_path} />
    <.nav_item icon="hero-queue-list" label="Background Tasks" href="/tasks" current_path={@current_path} />
    <.nav_item icon="hero-signal" label="Ports" href="/ports" current_path={@current_path} />
    <.nav_item icon="hero-magnifying-glass" label="Project Scanner" href="/scanner" current_path={@current_path} />
    <.nav_item icon="hero-beaker" label="UAT" href="/uat" current_path={@current_path} />
    <.nav_item icon="hero-document-text" label="Docs" href="/docs" current_path={@current_path} />
    """
  end

  # ── Components ───────────────────────────────────────────────────────────────
  attr :label, :string, required: true

  defp section_header(assigns) do
    ~H"""
    <div class="px-2 pt-3 pb-1 sidebar-label">
      <span class="text-[10px] font-semibold uppercase tracking-widest text-base-content/30">{@label}</span>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, required: true
  attr :current_path, :string, required: true
  attr :badge, :integer, default: 0
  attr :badge_label, :string, default: nil

  defp nav_item(assigns) do
    active =
      assigns.current_path == assigns.href ||
        (assigns.href != "/" && String.starts_with?(assigns.current_path || "", assigns.href))

    assigns = assign(assigns, :active, active)

    ~H"""
    <.link
      navigate={@href}
      class={[
        "flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-colors",
        @active && "bg-primary/10 text-primary font-medium",
        !@active && "text-base-content/60 hover:text-base-content hover:bg-base-300"
      ]}
    >
      <.icon name={@icon} class="size-4 flex-shrink-0" />
      <span class="sidebar-label">{@label}</span>
      <span :if={@badge > 0} class="badge badge-xs badge-primary ml-auto sidebar-badge">{@badge}</span>
      <span :if={@badge_label} class="badge badge-xs badge-accent ml-auto sidebar-badge">{@badge_label}</span>
    </.link>
    """
  end

  # ── Sub-item nav (indented, smaller, for plugin/integration children) ────────
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, required: true
  attr :current_path, :string, required: true
  attr :badge_label, :string, default: nil

  defp nav_sub_item(assigns) do
    active =
      assigns.current_path == assigns.href ||
        (assigns.href != "/" && String.starts_with?(assigns.current_path || "", assigns.href))

    assigns = assign(assigns, :active, active)

    ~H"""
    <.link
      navigate={@href}
      class={[
        "flex items-center gap-1.5 px-2 py-1 rounded text-xs transition-colors",
        @active && "bg-primary/10 text-primary font-medium",
        !@active && "text-base-content/50 hover:text-base-content/80 hover:bg-base-300/50"
      ]}
    >
      <.icon name={@icon} class="size-3 flex-shrink-0" />
      <span class="sidebar-label truncate">{@label}</span>
      <span :if={@badge_label} class="badge badge-xs badge-accent ml-auto sidebar-badge">{@badge_label}</span>
    </.link>
    """
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  @doc """
  Safely assigns sidebar nav data (plugins + integrations) to a LiveView socket.
  Call from `mount/3` to populate the dynamic sections.

  Wraps registry calls in try/rescue so sidebar rendering never fails if a
  registry GenServer is down.
  """
  def assign_sidebar_nav_data(socket) do
    plugins = safe_list_plugins()
    integrations = safe_list_integrations()

    socket
    |> Phoenix.Component.assign(:plugins, plugins)
    |> Phoenix.Component.assign(:integrations, integrations)
  end

  @doc "Safely list plugins; returns [] on any failure."
  @spec safe_list_plugins() :: [map()]
  def safe_list_plugins do
    try do
      ApmV5.Plugins.PluginRegistry.list_plugins()
    rescue
      _ -> []
    catch
      :exit, _ -> []
      _, _ -> []
    end
  end

  @doc "Safely list integrations; returns [] on any failure."
  @spec safe_list_integrations() :: [map()]
  def safe_list_integrations do
    try do
      ApmV5.Integrations.IntegrationRegistry.list_integrations()
    rescue
      _ -> []
    catch
      :exit, _ -> []
      _, _ -> []
    end
  end

  # Filter out integrations that already have dedicated sidebar entries
  # (ag-ui, ag_ui) to avoid duplication with the static AG-UI nav item.
  defp filtered_integrations(integrations) do
    Enum.reject(integrations, fn i ->
      name = i[:name] || i["name"] || ""
      slug = name |> to_string() |> String.downcase() |> String.replace(~r/[\s_-]/, "")
      slug in ["agui", "ralph"]
    end)
  end

  defp plugin_scope_icon(:apm), do: "hero-chart-bar"
  defp plugin_scope_icon(:ccem), do: "hero-cog-6-tooth"
  defp plugin_scope_icon(:claude_code), do: "hero-command-line"
  defp plugin_scope_icon(:security), do: "hero-shield-check"
  defp plugin_scope_icon(:memory), do: "hero-light-bulb"
  defp plugin_scope_icon(:orchestration), do: "hero-arrow-path-rounded-square"
  defp plugin_scope_icon(_), do: "hero-puzzle-piece"

  defp plugin_slug(plugin) do
    (plugin[:name] || plugin["name"] || "")
    |> to_string()
    |> String.downcase()
    |> String.replace(" ", "-")
  end

  defp plugin_href(plugin), do: "/plugins/#{plugin_slug(plugin)}"

  defp integration_slug(integ) do
    (integ[:name] || integ["name"] || "")
    |> to_string()
    |> String.downcase()
    |> String.replace(" ", "-")
  end

  defp integration_href(integ), do: "/integrations/#{integration_slug(integ)}"

  defp humanize_name(name) do
    name
    |> to_string()
    |> String.replace(["_", "-"], " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @app_version "9.1.1"
  defp version, do: @app_version
end
