defmodule ApmV5Web.Components.Feedback.CommandBar do
  @moduledoc """
  Tier 4 feedback — CommandBar (⌘K command palette, LiveComponent).

  Sourced from design-intake/v11.0.0/from-designer/apm-shell.jsx (CommandPalette).

  Implemented as a Phoenix.LiveComponent (mount + handle_event) so it can maintain
  its own query state and AI mode independently of the parent LiveView.

  Layout: backdrop (fixed inset 0, zIndex 300, bg oklch(0.1 0.01 255 / 0.55),
    paddingTop 12vh) + dialog (width 560, maxWidth 90%, bg surface-raised,
    border border-strong, borderRadius r-xl, boxShadow shadow-lg,
    animation `apm-modal-enter var(--apm-dur-base) var(--apm-ease-out)`).

  ⌘K row hover pseudo-state (pseudo-states.md §MenuItem):
    bg surface-overlay + 2px accent scan-line on left edge + soft glow
    (CSS `.cmd-row:hover` + `::before` pseudo-element with box-shadow accent-glow).

  AI mode: triggered when query contains '?', starts with 'why/how/what', or user
  presses Enter. Shows StreamingText response with action buttons.

  Icon changes: search icon (default) → spark icon (AI question detected).

  Groups data shape: `[%{group: String.t(), items: [%{icon: String.t(),
    label: String.t(), hint: String.t(), nav: String.t(), badge: String.t() | nil}]}]`

  ## JS hook
  # TODO: colocate feedback/command_bar.hook.js — CommandPalette hook (⌘K fuzzy
  # search + AI streaming, focus trap, keyboard navigation)
  # phx-hook="CommandPalette" on the input element.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-shell.jsx → CommandPalette
  - Pseudo-state matrix: pseudo-states.md §MenuItem (⌘K row hover)
  """
  use Phoenix.LiveComponent

  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="apm-command-bar-backdrop"
      phx-click="close"
      phx-target={@myself}
    >
      <div
        class="apm-command-bar"
        phx-click-away="close"
        phx-target={@myself}
      >
        <div class="apm-command-bar__search-row">
          <span class={["apm-command-bar__search-icon", @ai_question && "apm-command-bar__search-icon--ai"]} aria-hidden="true">
            <%= if @ai_question do %>
              <%!-- spark icon --%>
              <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2 2M16.4 16.4l2 2M18.4 5.6l-2 2M7.6 16.4l-2 2"/><circle cx="12" cy="12" r="2.5" fill="currentColor" stroke="none"/></svg>
            <% else %>
              <%!-- search icon --%>
              <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>
            <% end %>
          </span>
          <input
            id={"#{@id}-input"}
            class="apm-command-bar__input"
            type="text"
            placeholder="Search sessions, agents, formations — or ask a question…"
            value={@query}
            phx-change="query_changed"
            phx-keydown="key_pressed"
            phx-target={@myself}
            phx-hook="CommandPalette"
            autofocus
          />
          <span class="apm-kbd apm-mono" aria-label="Escape to close">esc</span>
        </div>
        <div class="apm-command-bar__results apm-scroll">
          <%= if @ai_mode do %>
            <div class="apm-command-bar__ai-answer">
              <div class="apm-command-bar__ai-header">
                <span class="apm-command-bar__ai-icon" aria-hidden="true">
                  <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M12 3v3M12 18v3M3 12h3M18 12h3"/><circle cx="12" cy="12" r="2.5" fill="currentColor" stroke="none"/></svg>
                </span>
                <span class="apm-mono apm-upper apm-command-bar__ai-label">AI · answering</span>
              </div>
              <div class="apm-command-bar__ai-body">
                <%!-- AI streaming content rendered here via StreamingText or push_event --%>
                {@ai_response}
              </div>
            </div>
          <% else %>
            <%= if @filtered_groups == [] do %>
              <div class="apm-command-bar__no-results">
                No matches. Press <span class="apm-kbd apm-mono">↵</span> to ask AI instead.
              </div>
            <% else %>
              <%= for group <- @filtered_groups do %>
                <div class="apm-command-bar__group">
                  <div class="apm-command-bar__group-label apm-upper">{group.group}</div>
                  <%= for item <- group.items do %>
                    <button
                      class="apm-command-bar__row cmd-row apm-focusable"
                      type="button"
                      phx-click="navigate"
                      phx-value-nav={item.nav}
                      phx-target={@myself}
                    >
                      <span class="apm-command-bar__row-icon" aria-hidden="true">
                        <ApmV5Web.Components.Core.Icon.icon name={item.icon} size={14} />
                      </span>
                      <span class="apm-command-bar__row-label">{item.label}</span>
                      <%= if item[:badge] do %>
                        <ApmV5Web.Components.Core.Badge.badge tone="warning">{item.badge}</ApmV5Web.Components.Core.Badge.badge>
                      <% end %>
                      <span class="apm-command-bar__row-hint apm-mono">{item[:hint]}</span>
                    </button>
                  <% end %>
                </div>
              <% end %>
            <% end %>
            <%= if @ai_question do %>
              <button
                class="apm-command-bar__ask-ai apm-focusable"
                type="button"
                phx-click="ask_ai"
                phx-target={@myself}
              >
                <span aria-hidden="true">
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M12 3v3M12 18v3M3 12h3M18 12h3"/><circle cx="12" cy="12" r="2.5" fill="currentColor" stroke="none"/></svg>
                </span>
                <span>Ask AI · "{@query}"</span>
                <span class="apm-kbd apm-mono">↵</span>
              </button>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  def mount(socket) do
    {:ok,
     assign(socket,
       query: "",
       ai_mode: false,
       ai_question: false,
       ai_response: "",
       filtered_groups: []
     )}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  def handle_event("query_changed", %{"value" => q}, socket) do
    ai_question =
      String.length(q) > 0 &&
        (String.contains?(q, "?") ||
           String.starts_with?(String.downcase(q), ~w(why how what)))

    {:noreply, assign(socket, query: q, ai_question: ai_question, ai_mode: false)}
  end

  def handle_event("key_pressed", %{"key" => "Enter"}, %{assigns: %{ai_question: true}} = socket) do
    {:noreply, assign(socket, ai_mode: true)}
  end

  def handle_event("key_pressed", %{"key" => "Escape"}, socket) do
    send(self(), {:command_bar_close})
    {:noreply, socket}
  end

  def handle_event("key_pressed", _params, socket), do: {:noreply, socket}

  def handle_event("ask_ai", _params, socket) do
    {:noreply, assign(socket, ai_mode: true)}
  end

  def handle_event("navigate", %{"nav" => nav}, socket) do
    send(self(), {:command_bar_navigate, nav})
    {:noreply, socket}
  end

  def handle_event("close", _params, socket) do
    send(self(), {:command_bar_close})
    {:noreply, socket}
  end
end
