defmodule ApmWeb.Components.CommandBar do
  @moduledoc """
  Global Cmd+K command bar LiveComponent.

  Provides keyboard-driven navigation across all APM pages. Renders a modal
  overlay with fuzzy-matched search over a static navigation manifest, grouped
  into Jump, Act, and Recent sections.

  ## Usage

      <.live_component module={ApmWeb.Components.CommandBar} id="command-bar" />

  The component is wired to the `CommandBar` JS hook which handles global
  keydown (Cmd+K / Ctrl+K) and pushes `toggle_command_bar` events.
  """

  use ApmWeb, :live_component

  # ---------------------------------------------------------------------------
  # Navigation manifest
  # ---------------------------------------------------------------------------

  @nav_items [
    # Jump — page navigation
    %{section: "jump", label: "Dashboard", path: "/", icon: "home", keywords: "home overview"},
    %{section: "jump", label: "Fleet", path: "/fleet", icon: "server", keywords: "agents active"},
    %{
      section: "jump",
      label: "Formations",
      path: "/formation",
      icon: "share-2",
      keywords: "swarm cluster topology"
    },
    %{
      section: "jump",
      label: "Timeline",
      path: "/timeline",
      icon: "clock",
      keywords: "session events history"
    },
    %{
      section: "jump",
      label: "Sessions",
      path: "/sessions",
      icon: "layers",
      keywords: "session manager"
    },
    %{
      section: "jump",
      label: "Conversations",
      path: "/conversations",
      icon: "message-square",
      keywords: "chat monitor"
    },
    %{
      section: "jump",
      label: "Analytics",
      path: "/analytics",
      icon: "bar-chart-2",
      keywords: "metrics stats"
    },
    %{section: "jump", label: "Usage", path: "/usage", icon: "activity", keywords: "tokens cost"},
    %{
      section: "jump",
      label: "Health",
      path: "/health",
      icon: "heart",
      keywords: "status uptime"
    },
    %{
      section: "jump",
      label: "Ports",
      path: "/ports",
      icon: "wifi",
      keywords: "network listeners"
    },
    %{
      section: "jump",
      label: "Tasks",
      path: "/tasks",
      icon: "check-square",
      keywords: "background jobs"
    },
    %{section: "jump", label: "Actions", path: "/actions", icon: "zap", keywords: "commands run"},
    %{
      section: "jump",
      label: "Scanner",
      path: "/scanner",
      icon: "search",
      keywords: "project scan"
    },
    %{
      section: "jump",
      label: "Skills",
      path: "/skills",
      icon: "package",
      keywords: "skill registry"
    },
    %{
      section: "jump",
      label: "Skill Drift",
      path: "/skill-drift",
      icon: "git-branch",
      keywords: "drift detect"
    },
    %{
      section: "jump",
      label: "Library",
      path: "/library",
      icon: "book-open",
      keywords: "documentation"
    },
    %{
      section: "jump",
      label: "Memory",
      path: "/memory",
      icon: "database",
      keywords: "observations vectorized"
    },
    %{
      section: "jump",
      label: "Orchestration",
      path: "/orchestration",
      icon: "cpu",
      keywords: "dag workflow"
    },
    %{
      section: "jump",
      label: "Approvals History",
      path: "/approvals-history",
      icon: "shield",
      keywords: "agentlock audit"
    },
    %{
      section: "jump",
      label: "Authorization",
      path: "/authorization",
      icon: "lock",
      keywords: "agentlock auth"
    },
    %{
      section: "jump",
      label: "Routing",
      path: "/routing",
      icon: "map",
      keywords: "channel route"
    },
    %{
      section: "jump",
      label: "Coalesce",
      path: "/coalesce",
      icon: "git-merge",
      keywords: "skill sync"
    },
    %{
      section: "jump",
      label: "UPM",
      path: "/upm/module",
      icon: "trello",
      keywords: "plane project management"
    },
    %{
      section: "jump",
      label: "Plugins",
      path: "/plugins",
      icon: "puzzle",
      keywords: "extensions"
    },
    %{
      section: "jump",
      label: "Integrations",
      path: "/integrations",
      icon: "link",
      keywords: "connect external"
    },
    %{
      section: "jump",
      label: "AG-UI",
      path: "/ag-ui",
      icon: "terminal",
      keywords: "agent ui protocol"
    },
    %{
      section: "jump",
      label: "Notifications",
      path: "/notifications",
      icon: "bell",
      keywords: "alerts events"
    },
    %{
      section: "jump",
      label: "Showcase",
      path: "/showcase",
      icon: "star",
      keywords: "projects portfolio"
    },
    %{
      section: "jump",
      label: "Docs",
      path: "/docs",
      icon: "file-text",
      keywords: "documentation reference"
    },
    %{
      section: "jump",
      label: "Architecture",
      path: "/architecture",
      icon: "box",
      keywords: "system design"
    },
    %{
      section: "jump",
      label: "UAT",
      path: "/uat",
      icon: "clipboard",
      keywords: "user acceptance test"
    },
    %{
      section: "jump",
      label: "DRTW",
      path: "/drtw",
      icon: "compass",
      keywords: "don't reinvent wheel"
    },
    %{section: "jump", label: "Intake", path: "/intake", icon: "inbox", keywords: "issue triage"},
    %{
      section: "jump",
      label: "Alignment",
      path: "/actions/alignment",
      icon: "align-center",
      keywords: "strategy goal"
    },
    %{
      section: "jump",
      label: "LVM Status",
      path: "/integrations/lvm",
      icon: "hard-drive",
      keywords: "lvm volume"
    },
    %{
      section: "jump",
      label: "Claude Code",
      path: "/plugins/claude-code",
      icon: "code",
      keywords: "claude plugin"
    },
    %{
      section: "jump",
      label: "Ralph Plugin",
      path: "/plugins/ralph",
      icon: "refresh-cw",
      keywords: "ralph loop plugin"
    },
    %{
      section: "jump",
      label: "AG-UI Plugin",
      path: "/plugins/ag_ui",
      icon: "terminal",
      keywords: "ag-ui plugin"
    },
    # Act — global actions
    %{
      section: "act",
      label: "Open API Docs",
      path: "/api/docs",
      icon: "book",
      keywords: "openapi swagger reference"
    },
    %{
      section: "act",
      label: "Tool Calls",
      path: "/tool-calls",
      icon: "code",
      keywords: "tool trace"
    },
    %{section: "act", label: "A2A", path: "/a2a", icon: "share", keywords: "agent to agent"},
    %{
      section: "act",
      label: "All Projects",
      path: "/apm-all",
      icon: "grid",
      keywords: "multi project"
    },
    %{
      section: "act",
      label: "Generative UI",
      path: "/generative-ui",
      icon: "layers",
      keywords: "genui"
    },
    %{
      section: "act",
      label: "CCEM Overview",
      path: "/ccem",
      icon: "info",
      keywords: "overview about"
    },
    %{
      section: "act",
      label: "Backfill",
      path: "/backfill",
      icon: "download",
      keywords: "data backfill"
    },
    %{
      section: "act",
      label: "Ralph Flow",
      path: "/ralph",
      icon: "refresh-cw",
      keywords: "ralph autonomous loop"
    }
  ]

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open, false)
     |> assign(:query, "")
     |> assign(:selected_index, 0)
     |> assign(:results, [])}
  end

  # ---------------------------------------------------------------------------
  # Event handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("toggle_command_bar", _params, socket) do
    if socket.assigns.open do
      {:noreply, close(socket)}
    else
      {:noreply, open(socket)}
    end
  end

  def handle_event("close_command_bar", _params, socket) do
    {:noreply, close(socket)}
  end

  def handle_event("command_bar_search", %{"query" => query}, socket) do
    results = filter_items(query)

    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:results, results)
     |> assign(:selected_index, 0)}
  end

  def handle_event("command_bar_navigate", %{"direction" => "down"}, socket) do
    count = length(socket.assigns.results)
    idx = min(socket.assigns.selected_index + 1, max(count - 1, 0))
    {:noreply, assign(socket, :selected_index, idx)}
  end

  def handle_event("command_bar_navigate", %{"direction" => "up"}, socket) do
    idx = max(socket.assigns.selected_index - 1, 0)
    {:noreply, assign(socket, :selected_index, idx)}
  end

  def handle_event("command_bar_select", _params, socket) do
    results = socket.assigns.results
    idx = socket.assigns.selected_index

    case Enum.at(results, idx) do
      %{path: path} ->
        {:noreply,
         socket
         |> close()
         |> push_navigate(to: path)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("command_bar_select_item", %{"index" => index_str}, socket) do
    idx = String.to_integer(index_str)

    case Enum.at(socket.assigns.results, idx) do
      %{path: path} ->
        {:noreply,
         socket
         |> close()
         |> push_navigate(to: path)}

      nil ->
        {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} phx-hook="CommandBar">
      <%= if @open do %>
        <%!-- Backdrop --%>
        <div
          class="command-bar-backdrop"
          phx-click="close_command_bar"
          phx-target={@myself}
          aria-hidden="true"
        />

        <%!-- Modal --%>
        <div
          class="command-bar-modal"
          role="dialog"
          aria-modal="true"
          aria-label="Command bar"
        >
          <%!-- Search input --%>
          <div class="command-bar-input-row">
            <svg
              class="command-bar-icon"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
            >
              <circle cx="11" cy="11" r="8" /><line x1="21" y1="21" x2="16.65" y2="16.65" />
            </svg>
            <input
              id="command-bar-input"
              type="text"
              class="command-bar-input"
              placeholder="Jump to page, run action…"
              value={@query}
              autocomplete="off"
              spellcheck="false"
              phx-keyup="command_bar_search"
              phx-key="any"
              phx-target={@myself}
              phx-debounce="0"
            />
            <kbd class="command-bar-esc-hint">esc</kbd>
          </div>

          <%!-- Results --%>
          <div class="command-bar-results" id="command-bar-results">
            <%= if @results == [] and @query == "" do %>
              <%!-- Default: show all sections --%>
              <%= for {section_key, section_label} <- [{"jump", "Jump to"}, {"act", "Actions"}] do %>
                <% section_items = Enum.filter(@results_default, &(&1.section == section_key)) %>
                <%= if section_items != [] do %>
                  <div class="command-bar-section-header">{section_label}</div>
                  <%= for {item, i} <- Enum.with_index(section_items) do %>
                    <button
                      class={"command-bar-item #{if i == @selected_index, do: "command-bar-item--selected"}"}
                      phx-click="command_bar_select_item"
                      phx-value-index={i}
                      phx-target={@myself}
                      tabindex="-1"
                    >
                      <span class="command-bar-item-label">{item.label}</span>
                      <span class="command-bar-item-path">{item.path}</span>
                    </button>
                  <% end %>
                <% end %>
              <% end %>
            <% else %>
              <%= if @results == [] do %>
                <div class="command-bar-empty">No results for "{@query}"</div>
              <% else %>
                <%!-- Grouped filtered results --%>
                <%= for {section_key, section_label} <- [{"jump", "Jump to"}, {"act", "Actions"}] do %>
                  <% section_items_with_idx =
                    @results
                    |> Enum.with_index()
                    |> Enum.filter(fn {item, _i} -> item.section == section_key end) %>
                  <%= if section_items_with_idx != [] do %>
                    <div class="command-bar-section-header">{section_label}</div>
                    <%= for {item, i} <- section_items_with_idx do %>
                      <button
                        class={"command-bar-item #{if i == @selected_index, do: "command-bar-item--selected"}"}
                        phx-click="command_bar_select_item"
                        phx-value-index={i}
                        phx-target={@myself}
                        tabindex="-1"
                      >
                        <span class="command-bar-item-label">{item.label}</span>
                        <span class="command-bar-item-path">{item.path}</span>
                      </button>
                    <% end %>
                  <% end %>
                <% end %>
              <% end %>
            <% end %>
          </div>

          <%!-- Footer hint --%>
          <div class="command-bar-footer">
            <span><kbd>↑↓</kbd> navigate</span>
            <span><kbd>↵</kbd> open</span>
            <span><kbd>esc</kbd> close</span>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec open(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp open(socket) do
    socket
    |> assign(:open, true)
    |> assign(:query, "")
    |> assign(:selected_index, 0)
    |> assign(:results, [])
    |> assign(:results_default, @nav_items)
  end

  @spec close(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp close(socket) do
    socket
    |> assign(:open, false)
    |> assign(:query, "")
    |> assign(:selected_index, 0)
    |> assign(:results, [])
  end

  @spec filter_items(String.t()) :: list(map())
  defp filter_items(""), do: @nav_items

  defp filter_items(query) do
    q = String.downcase(query)

    @nav_items
    |> Enum.filter(fn item ->
      haystack =
        "#{String.downcase(item.label)} #{String.downcase(item.path)} #{String.downcase(item.keywords)}"

      fuzzy_match?(haystack, q)
    end)
  end

  @spec fuzzy_match?(String.t(), String.t()) :: boolean()
  defp fuzzy_match?(haystack, query) do
    # Substring match first (fast path)
    if String.contains?(haystack, query) do
      true
    else
      # Character subsequence match (fuzzy)
      chars = String.graphemes(query)
      do_fuzzy(String.graphemes(haystack), chars)
    end
  end

  @spec do_fuzzy(list(String.t()), list(String.t())) :: boolean()
  defp do_fuzzy(_haystack, []), do: true
  defp do_fuzzy([], _chars), do: false

  defp do_fuzzy([h | rest_h], [c | rest_c]) do
    if h == c do
      do_fuzzy(rest_h, rest_c)
    else
      do_fuzzy(rest_h, [c | rest_c])
    end
  end
end
