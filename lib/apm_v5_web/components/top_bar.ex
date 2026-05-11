defmodule ApmV5Web.Components.TopBar do
  @moduledoc """
  CCEM APM top bar scaffolding component (CP-166 / US-441).

  Full-width, 48px-height bar rendered at the top of the layout shell.
  Uses only CSS custom properties from the CCEM design token layer — no
  Tailwind/daisyUI classes — so it compiles regardless of Tailwind config.

  ## Layout
  - Left: CCEM logotype + project switcher (`<details>`/`<summary>` dropdown,
    no JS required)
  - Right: ⌘K trigger button + presence stack (coloured dots, max 3 visible +
    overflow count) + account initials circle

  ## Usage

      <.top_bar
        project_name="CCEM"
        project_list={[{"proj-1", "CCEM"}, {"proj-2", "Lily AI"}]}
        active_project_id="proj-1"
        session_count={5}
        current_user="Jeremiah Pegues"
        on_project_change="switch_project"
        on_command_bar="open_command_bar"
      />
  """

  use Phoenix.Component

  # ---------------------------------------------------------------------------
  # Presence colours — cycle through three design-token colours
  # ---------------------------------------------------------------------------

  @presence_colors [
    "var(--ccem-iris)",
    "var(--ccem-ok)",
    "var(--ccem-accent)"
  ]

  # ---------------------------------------------------------------------------
  # top_bar/1
  # ---------------------------------------------------------------------------

  @doc """
  Renders the CCEM APM top bar.

  ## Attributes

  - `project_name`       — display name for the active project (default: "CCEM")
  - `project_list`       — list of `{id, name}` tuples for the project switcher
  - `active_project_id`  — id of the currently active project
  - `session_count`      — number of active sessions; drives the presence stack
  - `current_user`       — display name used to derive the account-circle initial
  - `on_project_change`  — `phx-click` event name fired on project selection
  - `on_command_bar`     — `phx-click` event name fired when ⌘K button is pressed
  - `class`              — additional CSS classes merged onto the root element
  - `rest`               — forwarded to the root `<header>` element
  """

  attr :project_name, :string, default: "CCEM"
  attr :project_list, :list, default: []
  attr :active_project_id, :string, default: nil
  attr :session_count, :integer, default: 0
  attr :current_user, :string, default: nil
  attr :on_project_change, :string, default: nil
  attr :on_command_bar, :string, default: nil
  attr :notification_count, :integer, default: 0
  attr :on_notifications, :string, default: "toggle_notifications"
  attr :class, :string, default: nil
  attr :rest, :global

  @spec top_bar(map()) :: Phoenix.LiveView.Rendered.t()
  def top_bar(assigns) do
    assigns =
      assigns
      |> assign(:presence_slots, build_presence_slots(assigns.session_count))
      |> assign(:account_initial, derive_initial(assigns.current_user))

    ~H"""
    <header
      id="apm-top-bar"
      class={@class}
      style={[
        "display: flex;",
        "align-items: center;",
        "justify-content: space-between;",
        "height: 48px;",
        "padding: 0 16px;",
        "background: var(--ccem-bg-1);",
        "border-bottom: 1px solid var(--ccem-line-subtle);",
        "font-family: var(--ccem-font-sans);",
        "gap: 12px;",
        "flex-shrink: 0;"
      ]}
      {@rest}
    >
      <!-- ── Left: logotype + project switcher ───────────────────────────── -->
      <div style="display: flex; align-items: center; gap: 12px; min-width: 0;">
        <!-- Logotype -->
        <span
          style={[
            "font-family: var(--ccem-font-mono, monospace);",
            "font-size: 14px;",
            "font-weight: 700;",
            "letter-spacing: 0.04em;",
            "white-space: nowrap;"
          ]}
          aria-label="CCEM APM"
        >
          <span style="color: var(--ccem-accent);">CCEM</span>
          <span style="color: var(--ccem-fg);"> APM</span>
        </span>

        <!-- Project switcher (details/summary — zero JS) -->
        <details style="position: relative;">
          <summary
            style={[
              "display: flex;",
              "align-items: center;",
              "gap: 6px;",
              "height: 28px;",
              "padding: 0 10px;",
              "background: var(--ccem-bg-2);",
              "border: 1px solid var(--ccem-line);",
              "border-radius: 14px;",
              "font-size: 12px;",
              "color: var(--ccem-fg);",
              "cursor: pointer;",
              "white-space: nowrap;",
              "list-style: none;",
              "user-select: none;"
            ]}
          >
            <span style="max-width: 160px; overflow: hidden; text-overflow: ellipsis;">
              {@project_name}
            </span>
            <span style="color: var(--ccem-fg-dim); font-size: 10px;">&#9660;</span>
          </summary>

          <!-- Dropdown — only rendered if there are entries to switch to -->
          <ul
            :if={@project_list != []}
            style={[
              "position: absolute;",
              "top: calc(100% + 4px);",
              "left: 0;",
              "z-index: 50;",
              "min-width: 180px;",
              "background: var(--ccem-bg-2);",
              "border: 1px solid var(--ccem-line);",
              "border-radius: 8px;",
              "padding: 4px;",
              "list-style: none;",
              "margin: 0;",
              "box-shadow: 0 4px 16px rgba(0,0,0,0.3);"
            ]}
          >
            <%= for {id, name} <- @project_list do %>
              <li
                phx-click={@on_project_change}
                phx-value-id={id}
                style={[
                  "display: flex;",
                  "align-items: center;",
                  "height: 32px;",
                  "padding: 0 10px;",
                  "border-radius: 6px;",
                  "font-size: 12px;",
                  "color: #{if id == @active_project_id, do: "var(--ccem-accent)", else: "var(--ccem-fg)"};",
                  "cursor: pointer;",
                  "white-space: nowrap;"
                ]}
              >
                {name}
              </li>
            <% end %>
          </ul>
        </details>
      </div>

      <!-- ── Right: ⌘K + presence stack + account ────────────────────────── -->
      <div style="display: flex; align-items: center; gap: 10px; flex-shrink: 0;">
        <!-- ⌘K trigger button -->
        <button
          :if={@on_command_bar}
          phx-click={@on_command_bar}
          title="Open command bar (⌘K)"
          aria-label="Open command bar"
          style={[
            "display: flex;",
            "align-items: center;",
            "justify-content: center;",
            "height: 28px;",
            "min-width: 40px;",
            "padding: 0 10px;",
            "background: var(--ccem-bg-2);",
            "border: 1px solid var(--ccem-line);",
            "border-radius: 6px;",
            "font-family: var(--ccem-font-mono, monospace);",
            "font-size: 11px;",
            "color: var(--ccem-fg-dim);",
            "cursor: pointer;",
            "white-space: nowrap;",
            "gap: 4px;"
          ]}
        >
          <span style="font-size: 12px;">&#8984;</span>
          <span>K</span>
        </button>

        <!-- Notifications bell -->
        <.notifications_bell count={@notification_count} on_click={@on_notifications} />

        <!-- Presence stack -->
        <.presence_stack slots={@presence_slots} session_count={@session_count} />

        <!-- Account circle -->
        <.account_circle initial={@account_initial} />
      </div>
    </header>
    """
  end

  # ---------------------------------------------------------------------------
  # notifications_bell/1 — bell icon button with unread count badge
  # ---------------------------------------------------------------------------

  attr :count, :integer, required: true
  attr :on_click, :string, default: nil

  defp notifications_bell(assigns) do
    ~H"""
    <button
      phx-click={@on_click}
      title={
        if @count > 0,
          do: "#{@count} unread notification#{if @count == 1, do: "", else: "s"}",
          else: "Notifications"
      }
      aria-label="Notifications"
      style={[
        "position: relative;",
        "display: flex;",
        "align-items: center;",
        "justify-content: center;",
        "width: 28px;",
        "height: 28px;",
        "background: var(--ccem-bg-2);",
        "border: 1px solid var(--ccem-line);",
        "border-radius: 6px;",
        "color: #{if @count > 0, do: "var(--ccem-accent)", else: "var(--ccem-fg-dim)"};",
        "cursor: pointer;",
        "padding: 0;",
        "flex-shrink: 0;"
      ]}
    >
      <!-- Bell glyph (Unicode 0x1F514 fallback to ‎-style; using \u{1F514} bell) -->
      <span style="font-size: 14px; line-height: 1;" aria-hidden="true">&#128276;</span>

      <!-- Unread count badge -->
      <span
        :if={@count > 0}
        style={[
          "position: absolute;",
          "top: -4px;",
          "right: -4px;",
          "min-width: 16px;",
          "height: 16px;",
          "padding: 0 4px;",
          "background: var(--ccem-err, #f87171);",
          "border: 1.5px solid var(--ccem-bg-1);",
          "border-radius: 8px;",
          "color: white;",
          "font-size: 10px;",
          "font-weight: 700;",
          "line-height: 13px;",
          "font-variant-numeric: tabular-nums;",
          "text-align: center;"
        ]}
      >
        {if @count > 99, do: "99+", else: to_string(@count)}
      </span>
    </button>
    """
  end

  # ---------------------------------------------------------------------------
  # presence_stack/1 — coloured dots + overflow label
  # ---------------------------------------------------------------------------

  attr :slots, :list, required: true
  attr :session_count, :integer, required: true

  defp presence_stack(assigns) do
    overflow = max(assigns.session_count - 3, 0)
    assigns = assign(assigns, :overflow, overflow)

    ~H"""
    <div
      :if={@session_count > 0}
      style="display: flex; align-items: center; gap: -4px; position: relative;"
      title={"#{@session_count} active session#{if @session_count == 1, do: "", else: "s"}"}
    >
      <!-- Coloured dot for each visible slot (max 3) -->
      <div style="display: flex; align-items: center;">
        <%= for {color, idx} <- @slots do %>
          <div
            style={[
              "width: 10px;",
              "height: 10px;",
              "border-radius: 50%;",
              "background: #{color};",
              "border: 1.5px solid var(--ccem-bg-1);",
              "margin-left: #{if idx == 0, do: "0", else: "-3px"};"
            ]}
          />
        <% end %>
      </div>

      <!-- Overflow count -->
      <span
        :if={@overflow > 0}
        style={[
          "font-size: 10px;",
          "color: var(--ccem-fg-dim);",
          "margin-left: 4px;",
          "white-space: nowrap;"
        ]}
      >
        +{@overflow}
      </span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # account_circle/1 — initials in a round badge
  # ---------------------------------------------------------------------------

  attr :initial, :string, required: true

  defp account_circle(assigns) do
    ~H"""
    <div
      title="Account"
      aria-label="Account"
      style={[
        "display: flex;",
        "align-items: center;",
        "justify-content: center;",
        "width: 28px;",
        "height: 28px;",
        "border-radius: 50%;",
        "background: var(--ccem-bg-3);",
        "border: 1px solid var(--ccem-iris);",
        "font-size: 12px;",
        "font-weight: 600;",
        "color: var(--ccem-fg);",
        "flex-shrink: 0;",
        "cursor: default;",
        "user-select: none;"
      ]}
    >
      {@initial}
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Returns a list of {color, index} tuples for up to 3 presence dots.
  @spec build_presence_slots(non_neg_integer()) :: [{String.t(), non_neg_integer()}]
  defp build_presence_slots(session_count) do
    visible = min(session_count, 3)
    colors = @presence_colors

    0..(visible - 1)
    |> Enum.map(fn idx -> {Enum.at(colors, rem(idx, length(colors))), idx} end)
  end

  # Returns the first letter (uppercase) of the user's display name, or "?".
  @spec derive_initial(String.t() | nil) :: String.t()
  defp derive_initial(nil), do: "?"
  defp derive_initial(""), do: "?"

  defp derive_initial(name) do
    name
    |> String.trim()
    |> String.first()
    |> String.upcase()
  end
end
