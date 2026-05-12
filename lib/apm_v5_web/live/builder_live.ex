defmodule ApmV5Web.BuilderLive do
  @moduledoc """
  LiveView for the Builder plugin at `/plugins/builder`.

  Five-step wizard:
    1. Identity   — plugin name + description
    2. Capabilities — checkboxes: skills, mcp, commands
    3. Source     — GitHub URL, local path, or .git path; triggers async analysis
    4. Preview    — generated plugin code + SKILL.md (read-only diff view)
    5. Write      — confirm and write files to disk

  Subscribes to `"builder:sessions"` PubSub so every BuilderEngine state
  change (analyzing, analyzed, generating, preview, complete) reflects
  instantly without polling.
  """

  use ApmV5Web, :live_view

  require Logger

  alias ApmV5.Plugins.Builder.BuilderEngine

  @pubsub_topic "builder:sessions"

  # ── Mount ────────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    {:ok, session_id} = BuilderEngine.start_session()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic)
    end

    {:ok, session} = BuilderEngine.get_session(session_id)

    socket =
      socket
      |> assign(:page_title, "Builder")
      |> assign(:session, session)
      |> assign(:step, 1)
      |> assign(:source_input, "")
      |> assign(:writing, false)
      |> assign(:write_result, nil)
      |> assign(:notification_count, 0)
      |> assign(:skill_count, 0)
      |> assign(:sidebar_collapsed, false)
      |> assign(:inspector_open, false)

    {:ok, socket}
  end

  # ── Render ───────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <ApmV5Web.Components.SidebarNav.sidebar_nav
          current_path="/plugins/builder"
          notification_count={@notification_count}
          skill_count={@skill_count}
        />
      </:sidebar>

      <:main>
        <div class="flex flex-col h-full">
          <%!-- Header --%>
          <div class="flex items-center justify-between px-6 py-4 border-b border-base-300">
            <div class="flex items-center gap-3">
              <.icon name="hero-wrench-screwdriver" class="w-5 h-5 text-accent" />
              <h1 class="text-lg font-semibold">Builder</h1>
              <.badge tone="accent">wizard</.badge>
            </div>
            <div class="flex items-center gap-2">
              <.badge tone={status_tone(@session.status)}>
                <%= @session.status %>
              </.badge>
            </div>
          </div>

          <%!-- Step progress --%>
          <div class="px-6 py-3 border-b border-base-300 flex items-center gap-2">
            <%= for {label, n} <- [{"Identity", 1}, {"Capabilities", 2}, {"Source", 3}, {"Preview", 4}, {"Write", 5}] do %>
              <div class={[
                "flex items-center gap-1 text-sm px-2 py-1 rounded",
                if(@step == n, do: "bg-accent/20 text-accent font-medium", else: "text-base-content/50")
              ]}>
                <span class={["w-5 h-5 rounded-full flex items-center justify-center text-xs font-bold",
                  cond do
                    n < @step -> "bg-ok text-ok-content"
                    n == @step -> "bg-accent text-accent-content"
                    true -> "bg-base-300 text-base-content/40"
                  end
                ]}>
                  <%= if n < @step, do: "✓", else: n %>
                </span>
                <%= label %>
              </div>
              <%= if n < 5 do %>
                <span class="text-base-content/20">›</span>
              <% end %>
            <% end %>
          </div>

          <%!-- Step body --%>
          <div class="flex-1 overflow-auto px-6 py-6 max-w-2xl">
            <%= case @step do %>
              <% 1 -> %>
                <.step_identity session={@session} />
              <% 2 -> %>
                <.step_capabilities session={@session} />
              <% 3 -> %>
                <.step_source session={@session} source_input={@source_input} />
              <% 4 -> %>
                <.step_preview session={@session} />
              <% 5 -> %>
                <.step_write session={@session} write_result={@write_result} writing={@writing} />
            <% end %>
          </div>

          <%!-- Navigation --%>
          <div class="px-6 py-4 border-t border-base-300 flex items-center justify-between">
            <.btn
              :if={@step > 1}
              phx-click="prev_step"
              variant="ghost"
              size="sm"
            >
              ← Back
            </.btn>
            <div :if={@step <= 1} />

            <%= cond do %>
              <% @step == 3 and @session.status in [:draft, :analyzed] -> %>
                <div class="flex gap-2">
                  <.btn
                    phx-click="analyze"
                    variant="secondary"
                    size="sm"
                    disabled={String.trim(@source_input) == ""}
                  >
                    Analyze source
                  </.btn>
                  <.btn
                    :if={@session.status == :analyzed}
                    phx-click="next_step"
                    size="sm"
                  >
                    Next →
                  </.btn>
                </div>
              <% @step == 4 and @session.status in [:analyzed, :preview] -> %>
                <div class="flex gap-2">
                  <.btn
                    :if={@session.status == :analyzed}
                    phx-click="generate"
                    variant="secondary"
                    size="sm"
                  >
                    Generate preview
                  </.btn>
                  <.btn
                    :if={@session.status == :preview}
                    phx-click="next_step"
                    size="sm"
                  >
                    Next →
                  </.btn>
                </div>
              <% @step == 5 -> %>
                <.btn
                  phx-click="write_files"
                  size="sm"
                  disabled={@writing or @session.status == :complete}
                >
                  <%= if @writing, do: "Writing…", else: "Write files" %>
                </.btn>
              <% @step < 3 -> %>
                <.btn phx-click="next_step" size="sm">
                  Next →
                </.btn>
              <% true -> %>
                <div />
            <% end %>
          </div>
        </div>
      </:main>
    </.page_layout>
    """
  end

  # ── Step Components ──────────────────────────────────────────────────────────

  attr :session, :map, required: true

  defp step_identity(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h2 class="text-base font-semibold mb-1">Plugin identity</h2>
        <p class="text-sm text-base-content/60">Give your plugin a name and a one-line description.</p>
      </div>
      <div class="space-y-4">
        <div>
          <label class="label"><span class="label-text">Name</span></label>
          <input
            class="input input-bordered w-full"
            type="text"
            placeholder="my-plugin"
            value={@session.name || ""}
            phx-change="update_name"
            phx-debounce="300"
            name="name"
          />
        </div>
        <div>
          <label class="label"><span class="label-text">Description</span></label>
          <textarea
            class="textarea textarea-bordered w-full"
            rows="3"
            placeholder="What does this plugin do?"
            phx-change="update_description"
            phx-debounce="300"
            name="description"
          ><%= @session.description %></textarea>
        </div>
      </div>
    </div>
    """
  end

  attr :session, :map, required: true

  defp step_capabilities(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h2 class="text-base font-semibold mb-1">Capabilities</h2>
        <p class="text-sm text-base-content/60">Select which Claude Code capabilities this plugin should scaffold.</p>
      </div>
      <div class="space-y-3">
        <%= for {cap, label, desc} <- [
          {:skills, "Skills", "Claude Code skills (.claude/skills/)"},
          {:mcp, "MCP Servers", "Model Context Protocol server configuration"},
          {:commands, "Commands", "Custom slash commands (.claude/commands/)"}
        ] do %>
          <label class="flex items-start gap-3 p-3 rounded-lg border border-base-300 cursor-pointer hover:bg-base-200">
            <input
              type="checkbox"
              class="checkbox checkbox-accent mt-0.5"
              checked={cap in (@session.capabilities || [])}
              phx-click="toggle_capability"
              phx-value-cap={cap}
            />
            <div>
              <div class="text-sm font-medium"><%= label %></div>
              <div class="text-xs text-base-content/60"><%= desc %></div>
            </div>
          </label>
        <% end %>
      </div>
    </div>
    """
  end

  attr :session, :map, required: true
  attr :source_input, :string, required: true

  defp step_source(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h2 class="text-base font-semibold mb-1">Source repository</h2>
        <p class="text-sm text-base-content/60">
          Provide a GitHub URL, local path, or .git path. The analyzer will clone or read it
          to detect language, README, and capabilities.
        </p>
      </div>
      <div>
        <label class="label"><span class="label-text">Source</span></label>
        <input
          class="input input-bordered w-full font-mono text-sm"
          type="text"
          placeholder="https://github.com/owner/repo  or  ~/Developer/myproject"
          value={@source_input}
          phx-change="update_source_input"
          phx-debounce="200"
          name="source"
        />
        <div class="mt-2 flex gap-2 flex-wrap">
          <span class="text-xs text-base-content/40">Examples:</span>
          <code class="text-xs text-accent/80">https://github.com/h4ckf0r0day/obscura</code>
          <code class="text-xs text-accent/80">~/Developer/idfw</code>
        </div>
      </div>

      <%= if @session.status == :analyzing do %>
        <div class="flex items-center gap-2 text-sm text-base-content/60">
          <span class="loading loading-spinner loading-xs"></span>
          Analyzing source…
        </div>
      <% end %>

      <%= if @session.status == :analyzed and @session.analyzed do %>
        <div class="rounded-lg border border-ok/30 bg-ok/10 p-4 space-y-2">
          <div class="flex items-center gap-2 text-sm font-medium text-ok">
            <.icon name="hero-check-circle" class="w-4 h-4" />
            Analysis complete
          </div>
          <div class="grid grid-cols-2 gap-2 text-xs text-base-content/70">
            <div>Language: <span class="font-mono"><%= @session.analyzed[:language] || "unknown" %></span></div>
            <div>Capabilities detected: <span class="font-mono"><%= length(@session.analyzed[:capabilities] || []) %></span></div>
          </div>
          <%= if @session.analyzed[:description_hint] != "" do %>
            <p class="text-xs text-base-content/60 italic"><%= @session.analyzed[:description_hint] %></p>
          <% end %>
        </div>
      <% end %>

      <%= if @session.status == :error do %>
        <div class="rounded-lg border border-err/30 bg-err/10 p-4 text-sm text-err">
          Analysis failed: <%= inspect(@session.error) %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :session, :map, required: true

  defp step_preview(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h2 class="text-base font-semibold mb-1">Preview</h2>
        <p class="text-sm text-base-content/60">Review the generated plugin module and SKILL.md before writing.</p>
      </div>

      <%= if @session.status == :generating do %>
        <div class="flex items-center gap-2 text-sm text-base-content/60">
          <span class="loading loading-spinner loading-xs"></span>
          Generating code…
        </div>
      <% end %>

      <%= if @session.generated_plugin_code do %>
        <div>
          <div class="text-xs font-medium text-base-content/60 mb-1 font-mono">Plugin module (.ex)</div>
          <pre class="bg-base-300 rounded-lg p-4 text-xs font-mono overflow-auto max-h-64 whitespace-pre-wrap"><%= @session.generated_plugin_code %></pre>
        </div>
      <% end %>

      <%= if @session.generated_skill_md do %>
        <div>
          <div class="text-xs font-medium text-base-content/60 mb-1 font-mono">SKILL.md</div>
          <pre class="bg-base-300 rounded-lg p-4 text-xs font-mono overflow-auto max-h-48 whitespace-pre-wrap"><%= @session.generated_skill_md %></pre>
        </div>
      <% end %>

      <%= if is_nil(@session.generated_plugin_code) and @session.status != :generating do %>
        <p class="text-sm text-base-content/50">Click "Generate preview" to create the plugin scaffold.</p>
      <% end %>
    </div>
    """
  end

  attr :session, :map, required: true
  attr :write_result, :any, required: true
  attr :writing, :boolean, required: true

  defp step_write(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h2 class="text-base font-semibold mb-1">Write files</h2>
        <p class="text-sm text-base-content/60">
          This will write the plugin module and SKILL.md to disk.
        </p>
      </div>

      <div class="space-y-3 rounded-lg border border-base-300 p-4 text-sm font-mono">
        <div class="text-base-content/60">Files to be written:</div>
        <div>lib/apm_v5/plugins/<%= slug_for(@session) %>/<%= slug_for(@session) %>_plugin.ex</div>
        <div>~/.claude/skills/<%= slug_for(@session) %>/SKILL.md</div>
      </div>

      <%= if @write_result do %>
        <%= case @write_result do %>
          <% {:ok, paths} -> %>
            <div class="rounded-lg border border-ok/30 bg-ok/10 p-4 space-y-2">
              <div class="flex items-center gap-2 text-sm font-medium text-ok">
                <.icon name="hero-check-circle" class="w-4 h-4" />
                Files written successfully
              </div>
              <ul class="text-xs font-mono text-base-content/70 space-y-1">
                <%= for path <- paths do %>
                  <li><%= path %></li>
                <% end %>
              </ul>
            </div>
          <% {:error, reason} -> %>
            <div class="rounded-lg border border-err/30 bg-err/10 p-4 text-sm text-err">
              Write failed: <%= inspect(reason) %>
            </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  # ── Events ───────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("update_name", %{"name" => name}, socket) do
    BuilderEngine.update_session(socket.assigns.session.id, %{name: name})
    {:noreply, socket}
  end

  def handle_event("update_description", %{"description" => desc}, socket) do
    BuilderEngine.update_session(socket.assigns.session.id, %{description: desc})
    {:noreply, socket}
  end

  def handle_event("toggle_capability", %{"cap" => cap_str}, socket) do
    cap = String.to_atom(cap_str)
    caps = socket.assigns.session.capabilities || []

    updated_caps =
      if cap in caps, do: List.delete(caps, cap), else: [cap | caps]

    BuilderEngine.update_session(socket.assigns.session.id, %{capabilities: updated_caps})
    {:noreply, socket}
  end

  def handle_event("update_source_input", %{"source" => src}, socket) do
    {:noreply, assign(socket, :source_input, src)}
  end

  def handle_event("analyze", _params, socket) do
    source = String.trim(socket.assigns.source_input)
    id = socket.assigns.session.id
    BuilderEngine.update_session(id, %{source: source})
    BuilderEngine.analyze_source(id)
    {:noreply, socket}
  end

  def handle_event("generate", _params, socket) do
    BuilderEngine.generate_preview(socket.assigns.session.id)
    {:noreply, socket}
  end

  def handle_event("write_files", _params, socket) do
    socket = assign(socket, :writing, true)

    result = BuilderEngine.write_files(socket.assigns.session.id)

    {:noreply, socket |> assign(:write_result, result) |> assign(:writing, false)}
  end

  def handle_event("next_step", _params, socket) do
    {:noreply, assign(socket, :step, min(socket.assigns.step + 1, 5))}
  end

  def handle_event("prev_step", _params, socket) do
    {:noreply, assign(socket, :step, max(socket.assigns.step - 1, 1))}
  end

  # ── PubSub ───────────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:builder_session_updated, session}, socket) do
    if session.id == socket.assigns.session.id do
      socket = assign(socket, :session, session)

      socket =
        case session.status do
          :analyzed when socket.assigns.step == 3 -> assign(socket, :step, 3)
          :preview when socket.assigns.step == 4 -> assign(socket, :step, 4)
          _ -> socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Private ──────────────────────────────────────────────────────────────────

  defp status_tone(:draft), do: "neutral"
  defp status_tone(:analyzing), do: "info"
  defp status_tone(:analyzed), do: "ok"
  defp status_tone(:generating), do: "info"
  defp status_tone(:preview), do: "accent"
  defp status_tone(:writing), do: "warn"
  defp status_tone(:complete), do: "ok"
  defp status_tone(:error), do: "err"
  defp status_tone(_), do: "neutral"

  defp slug_for(session) do
    (session.name || "plugin")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
