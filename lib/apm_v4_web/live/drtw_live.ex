defmodule ApmV4Web.DrtwLive do
  @moduledoc """
  LiveView for the DRTW (Don't Reinvent The Wheel) discovery framework.

  Displays the DRTW scoring criteria, lists user-scope skills available
  at ~/.claude/skills/, and links to the aitmpl.com/skills community registry.
  """

  use ApmV4Web, :live_view

  @skills_dir "~/.claude/skills"

  @impl true
  def mount(_params, _session, socket) do
    skills = list_skills()

    {:ok,
     socket
     |> assign(:page_title, "DRTW")
     |> assign(:skills, skills)}
  end

  defp list_skills do
    expanded = Path.expand(@skills_dir)

    case System.cmd("ls", ["-1", expanded], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.sort()

      {_error, _} ->
        []
    end
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
          <.nav_item icon="hero-circle-stack" label="UPM" active={false} href="/upm" />
          <.nav_item icon="hero-clock" label="Timeline" active={false} href="/timeline" />
          <.nav_item icon="hero-bell" label="Notifications" active={false} href="/notifications" />
          <.nav_item icon="hero-queue-list" label="Background Tasks" active={false} href="/tasks" />
          <.nav_item icon="hero-magnifying-glass" label="Project Scanner" active={false} href="/scanner" />
          <.nav_item icon="hero-bolt" label="Actions" active={false} href="/actions" />
          <.nav_item icon="hero-sparkles" label="Skills" active={false} href="/skills" />
          <.nav_item icon="hero-arrow-path" label="Ralph" active={false} href="/ralph" />
          <.nav_item icon="hero-signal" label="Ports" active={false} href="/ports" />
          <.nav_item icon="hero-book-open" label="Docs" active={false} href="/docs" />
          <.nav_item icon="hero-wrench-screwdriver" label="DRTW" active={true} href="/drtw" />
        </nav>
      </aside>

      <%!-- Main content --%>
      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Header --%>
        <header class="h-12 bg-base-200 border-b border-base-300 flex items-center justify-between px-4 flex-shrink-0">
          <div class="flex items-center gap-3">
            <h2 class="text-sm font-semibold text-base-content">DRTW — Don't Reinvent The Wheel</h2>
            <div class="badge badge-sm badge-ghost">{length(@skills)} skills available</div>
          </div>
          <a
            href="https://www.aitmpl.com/skills"
            target="_blank"
            rel="noopener noreferrer"
            class="btn btn-primary btn-sm gap-2"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4" />
            Community Registry
          </a>
        </header>

        <%!-- Body --%>
        <div class="flex-1 overflow-y-auto p-4 space-y-6">

          <%!-- Discovery Priority --%>
          <section>
            <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3">
              Discovery Priority (L1 → L5)
            </h3>
            <div class="grid grid-cols-1 md:grid-cols-5 gap-3">
              <div class="card bg-base-200 border border-base-300 p-3">
                <div class="badge badge-primary badge-sm mb-2">L1</div>
                <p class="text-sm font-medium">Installed Packages</p>
                <p class="text-xs text-base-content/50 mt-1">
                  Check <code class="text-primary">package.json</code> and <code class="text-primary">mix.exs</code> first
                </p>
              </div>
              <div class="card bg-base-200 border border-base-300 p-3">
                <div class="badge badge-secondary badge-sm mb-2">L2</div>
                <p class="text-sm font-medium">Platform / Stdlib</p>
                <p class="text-xs text-base-content/50 mt-1">
                  Native OS tools, Elixir stdlib, Node built-ins
                </p>
              </div>
              <div class="card bg-base-200 border border-base-300 p-3">
                <div class="badge badge-accent badge-sm mb-2">L3</div>
                <p class="text-sm font-medium">Internal Skills</p>
                <p class="text-xs text-base-content/50 mt-1">
                  <code class="text-primary">~/.claude/skills/</code> — see table below
                </p>
              </div>
              <div class="card bg-base-200 border border-base-300 p-3">
                <div class="badge badge-info badge-sm mb-2">L4</div>
                <p class="text-sm font-medium">Community Registry</p>
                <p class="text-xs text-base-content/50 mt-1">
                  aitmpl.com, npm, hex.pm, pypi
                </p>
              </div>
              <div class="card bg-base-200 border border-base-300 p-3">
                <div class="badge badge-ghost badge-sm mb-2">L5</div>
                <p class="text-sm font-medium">Custom Build</p>
                <p class="text-xs text-base-content/50 mt-1">
                  Only after L1–L4 exhausted
                </p>
              </div>
            </div>
          </section>

          <%!-- CCEM-specific Patterns --%>
          <section>
            <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3">
              CCEM-Specific Reuse Patterns
            </h3>
            <div class="overflow-x-auto">
              <table class="table table-xs w-full">
                <thead>
                  <tr class="text-[10px] uppercase tracking-wider text-base-content/40">
                    <th>Need</th>
                    <th>Existing Solution</th>
                    <th>Type</th>
                  </tr>
                </thead>
                <tbody>
                  <tr class="hover">
                    <td>APM notifications</td>
                    <td><code>POST /api/notify</code></td>
                    <td><span class="badge badge-xs badge-success">API endpoint</span></td>
                  </tr>
                  <tr class="hover">
                    <td>Agent heartbeats</td>
                    <td><code>POST /api/heartbeat</code></td>
                    <td><span class="badge badge-xs badge-success">API endpoint</span></td>
                  </tr>
                  <tr class="hover">
                    <td>Formation tracking</td>
                    <td><code>POST /api/upm/register</code></td>
                    <td><span class="badge badge-xs badge-success">API endpoint</span></td>
                  </tr>
                  <tr class="hover">
                    <td>Background tasks</td>
                    <td><code>BackgroundTasksStore</code> GenServer</td>
                    <td><span class="badge badge-xs badge-info">GenServer</span></td>
                  </tr>
                  <tr class="hover">
                    <td>Project scanning</td>
                    <td><code>ProjectScanner</code> GenServer</td>
                    <td><span class="badge badge-xs badge-info">GenServer</span></td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>

          <%!-- Available Skills --%>
          <section>
            <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3">
              Available Skills — <code>~/.claude/skills/</code>
            </h3>
            <div :if={@skills == []} class="text-sm text-base-content/30 py-4">
              No skills found or directory not accessible.
            </div>
            <div class="overflow-x-auto">
              <table class="table table-xs w-full">
                <thead>
                  <tr class="text-[10px] uppercase tracking-wider text-base-content/40">
                    <th>#</th>
                    <th>Skill Name</th>
                    <th>Invoke</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={{skill, idx} <- Enum.with_index(@skills, 1)} class="hover">
                    <td class="tabular-nums text-base-content/40">{idx}</td>
                    <td class="font-medium">{skill}</td>
                    <td><code class="text-xs text-primary">/{skill}</code></td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>

          <%!-- Community Link --%>
          <section>
            <div class="card bg-base-200 border border-base-300 p-4">
              <div class="flex items-center justify-between">
                <div>
                  <h3 class="text-sm font-semibold">Community Skills Registry</h3>
                  <p class="text-xs text-base-content/50 mt-1">
                    Browse and contribute community skills before writing custom implementations.
                  </p>
                </div>
                <a
                  href="https://www.aitmpl.com/skills"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="btn btn-outline btn-sm gap-2"
                >
                  <.icon name="hero-arrow-top-right-on-square" class="size-4" />
                  aitmpl.com/skills
                </a>
              </div>
            </div>
          </section>

        </div>
      </div>
    </div>
    """
  end
end
