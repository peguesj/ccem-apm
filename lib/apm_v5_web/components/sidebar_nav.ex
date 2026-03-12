defmodule ApmV5Web.Components.SidebarNav do
  @moduledoc "Shared sidebar navigation component for all LiveViews."
  use Phoenix.Component
  import ApmV5Web.CoreComponents, only: [icon: 1]

  attr :current_path, :string, required: true
  attr :notification_count, :integer, default: 0
  attr :skill_count, :integer, default: 0

  def sidebar_nav(assigns) do
    assigns = assign(assigns, :version, version())

    ~H"""
    <aside class="w-52 bg-base-200 border-r border-base-300 flex flex-col flex-shrink-0">
      <div class="p-3 border-b border-base-300">
        <div class="flex items-center gap-2">
          <div class="w-2 h-2 rounded-full bg-success animate-pulse"></div>
          <span class="font-mono font-bold text-sm text-base-content">CCEM APM</span>
        </div>
        <div class="text-xs text-base-content/40 mt-0.5">v{@version}</div>
      </div>
      <nav class="flex-1 p-2 space-y-0.5 overflow-y-auto" aria-label="Main navigation">
        <.nav_item icon="hero-squares-2x2" label="Dashboard" href="/" current_path={@current_path} />
        <.nav_item icon="hero-globe-alt" label="All Projects" href="/apm-all" current_path={@current_path} />
        <.nav_item icon="hero-rectangle-group" label="Formations" href="/formation" current_path={@current_path} />
        <.nav_item icon="hero-clock" label="Timeline" href="/timeline" current_path={@current_path} />
        <.nav_item icon="hero-bell" label="Notifications" href="/notifications" current_path={@current_path} badge={@notification_count} />
        <.nav_item icon="hero-queue-list" label="Background Tasks" href="/tasks" current_path={@current_path} />
        <.nav_item icon="hero-magnifying-glass" label="Project Scanner" href="/scanner" current_path={@current_path} />
        <.nav_item icon="hero-bolt" label="Actions" href="/actions" current_path={@current_path} />
        <.nav_item icon="hero-sparkles" label="Skills" href="/skills" current_path={@current_path} badge={@skill_count} />
        <.nav_item icon="hero-arrow-path" label="Ralph" href="/ralph" current_path={@current_path} />
        <.nav_item icon="hero-signal" label="Ports" href="/ports" current_path={@current_path} />
        <.nav_item icon="hero-chart-bar" label="Analytics" href="/analytics" current_path={@current_path} />
        <.nav_item icon="hero-heart" label="Health" href="/health" current_path={@current_path} />
        <.nav_item icon="hero-cpu-chip" label="AG-UI" href="/ag-ui" current_path={@current_path} />
        <.nav_item icon="hero-beaker" label="UAT" href="/uat" current_path={@current_path} />
        <.nav_item icon="hero-chat-bubble-left-right" label="Conversations" href="/conversations" current_path={@current_path} />
        <.nav_item icon="hero-puzzle-piece" label="Plugins" href="/plugins" current_path={@current_path} />
        <.nav_item icon="hero-book-open" label="Docs" href="/docs" current_path={@current_path} />
      </nav>
    </aside>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, required: true
  attr :current_path, :string, required: true
  attr :badge, :integer, default: 0

  defp nav_item(assigns) do
    active =
      assigns.current_path == assigns.href ||
        (assigns.href != "/" && String.starts_with?(assigns.current_path || "", assigns.href))

    assigns = assign(assigns, :active, active)

    ~H"""
    <a
      href={@href}
      class={[
        "flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-colors",
        @active && "bg-primary/10 text-primary font-medium",
        !@active && "text-base-content/60 hover:text-base-content hover:bg-base-300"
      ]}
    >
      <.icon name={@icon} class="size-4 flex-shrink-0" />
      <span>{@label}</span>
      <span :if={@badge > 0} class="badge badge-xs badge-primary ml-auto">{@badge}</span>
    </a>
    """
  end

  defp version do
    case Application.spec(:apm_v5, :vsn) do
      nil -> "5.2.0"
      vsn -> to_string(vsn)
    end
  end
end
