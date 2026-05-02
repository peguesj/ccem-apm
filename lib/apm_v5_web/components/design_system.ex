defmodule ApmV5Web.Components.DesignSystem do
  @moduledoc """
  CCEM Design System primitive components for Phoenix LiveView.

  All components reference CSS custom properties defined under the `:root`
  selector in `assets/css/app.css` with the `--ccem-*` prefix. Components
  are plain function components — not LiveComponents — and can be imported
  into any LiveView or HTML module.

  ## Usage

      import ApmV5Web.Components.DesignSystem

      <.btn variant="primary" size="md" type="button">Save</.btn>
      <.badge tone="ok" dot>Running</.badge>
      <.card><p>Hello</p></.card>
  """

  use Phoenix.Component

  # ---------------------------------------------------------------------------
  # btn/1
  # ---------------------------------------------------------------------------

  @doc """
  Renders a button with one of five variants and four size options.

  ## Variants
  - `primary`     — lime accent background
  - `secondary`   — bg-2 surface with border (default)
  - `ghost`       — transparent background
  - `destructive` — error-tone background
  - `icon`        — square aspect ratio, no label padding

  ## Sizes
  - `xs` — h-6, 11px text
  - `sm` — h-7, 12px text
  - `md` — h-8, 13px text (default)
  - `lg` — h-10, 14px text

  ## Examples

      <.btn>Cancel</.btn>
      <.btn variant="primary" size="lg" type="submit">Save Changes</.btn>
      <.btn variant="destructive" phx-click="delete">Delete</.btn>
      <.btn variant="icon" size="sm" phx-click="close">✕</.btn>
  """
  attr :variant, :string,
    default: "secondary",
    values: ~w(primary secondary ghost destructive icon)

  attr :size, :string, default: "md", values: ~w(xs sm md lg)

  attr :rest, :global,
    include: ~w(disabled form name value type phx-click phx-disable-with phx-target
                aria-label aria-describedby tabindex autofocus)

  slot :inner_block, required: true

  def btn(assigns) do
    assigns =
      assign(assigns,
        variant_style: btn_variant_style(assigns.variant),
        size_style: btn_size_style(assigns.size)
      )

    ~H"""
    <button
      style={
        "display: inline-flex; align-items: center; justify-content: center; " <>
          "border-radius: var(--ccem-r-sm, 5px); " <>
          "font-family: var(--ccem-font-sans, inherit); " <>
          "font-weight: 500; cursor: pointer; " <>
          "transition: background 120ms ease, color 120ms ease, border-color 120ms ease, opacity 120ms ease; " <>
          "outline-offset: 2px; user-select: none; " <>
          @variant_style <> @size_style
      }
      class="ccem-focus"
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp btn_variant_style("primary") do
    "background: var(--ccem-accent); color: var(--ccem-accent-fg, #000); border: 1px solid transparent;"
  end

  defp btn_variant_style("secondary") do
    "background: var(--ccem-bg-2); color: var(--ccem-fg); border: 1px solid var(--ccem-line);"
  end

  defp btn_variant_style("ghost") do
    "background: transparent; color: var(--ccem-fg); border: 1px solid transparent;"
  end

  defp btn_variant_style("destructive") do
    "background: var(--ccem-err); color: var(--ccem-err-fg, #fff); border: 1px solid transparent;"
  end

  defp btn_variant_style("icon") do
    "background: var(--ccem-bg-2); color: var(--ccem-fg); border: 1px solid var(--ccem-line); aspect-ratio: 1 / 1; padding: 0;"
  end

  defp btn_size_style("xs"), do: "height: 1.5rem; padding: 0 0.5rem; font-size: 11px; gap: 4px;"
  defp btn_size_style("sm"), do: "height: 1.75rem; padding: 0 0.625rem; font-size: 12px; gap: 4px;"
  defp btn_size_style("md"), do: "height: 2rem; padding: 0 0.75rem; font-size: 13px; gap: 6px;"
  defp btn_size_style("lg"), do: "height: 2.5rem; padding: 0 1rem; font-size: 14px; gap: 6px;"

  # ---------------------------------------------------------------------------
  # badge/1
  # ---------------------------------------------------------------------------

  @doc """
  Renders a status badge with seven tone options.

  ## Tones
  `accent`, `iris`, `ok`, `warn`, `err`, `info`, `neutral`

  ## Options
  - `dot`    — shows an animated pulsing indicator dot
  - `square` — disables the pill shape (uses 5px radius instead)

  ## Examples

      <.badge tone="ok">Healthy</.badge>
      <.badge tone="err" dot>Failed</.badge>
      <.badge tone="warn" square>3</.badge>
  """
  attr :tone, :string,
    default: "neutral",
    values: ~w(accent iris ok warn err info neutral)

  attr :dot, :boolean, default: false
  attr :square, :boolean, default: false
  attr :rest, :global

  slot :inner_block, required: true

  def badge(assigns) do
    assigns =
      assign(assigns,
        tone_style: badge_tone_style(assigns.tone),
        radius_style: if(assigns.square, do: "border-radius: 5px;", else: "border-radius: 999px;")
      )

    ~H"""
    <span
      style={
        "display: inline-flex; align-items: center; gap: 5px; " <>
          "padding: 1px 7px; font-size: 11px; " <>
          "font-family: var(--ccem-font-mono, monospace); font-weight: 500; " <>
          "line-height: 1.6; white-space: nowrap; " <>
          @radius_style <> @tone_style
      }
      {@rest}
    >
      <span
        :if={@dot}
        class="ccem-pulse"
        style="display: inline-block; width: 6px; height: 6px; border-radius: 50%; background: currentColor; flex-shrink: 0;"
      />
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_tone_style("accent"),
    do: "background: var(--ccem-accent-muted, color-mix(in srgb, var(--ccem-accent) 18%, transparent)); color: var(--ccem-accent); border: 1px solid color-mix(in srgb, var(--ccem-accent) 30%, transparent);"

  defp badge_tone_style("iris"),
    do: "background: var(--ccem-iris-muted, color-mix(in srgb, var(--ccem-iris, #7c6cf8) 18%, transparent)); color: var(--ccem-iris, #7c6cf8); border: 1px solid color-mix(in srgb, var(--ccem-iris, #7c6cf8) 30%, transparent);"

  defp badge_tone_style("ok"),
    do: "background: color-mix(in srgb, var(--ccem-ok, #22c55e) 15%, transparent); color: var(--ccem-ok, #22c55e); border: 1px solid color-mix(in srgb, var(--ccem-ok, #22c55e) 30%, transparent);"

  defp badge_tone_style("warn"),
    do: "background: color-mix(in srgb, var(--ccem-warn, #f59e0b) 15%, transparent); color: var(--ccem-warn, #f59e0b); border: 1px solid color-mix(in srgb, var(--ccem-warn, #f59e0b) 30%, transparent);"

  defp badge_tone_style("err"),
    do: "background: color-mix(in srgb, var(--ccem-err, #ef4444) 15%, transparent); color: var(--ccem-err, #ef4444); border: 1px solid color-mix(in srgb, var(--ccem-err, #ef4444) 30%, transparent);"

  defp badge_tone_style("info"),
    do: "background: color-mix(in srgb, var(--ccem-info, #3b82f6) 15%, transparent); color: var(--ccem-info, #3b82f6); border: 1px solid color-mix(in srgb, var(--ccem-info, #3b82f6) 30%, transparent);"

  defp badge_tone_style("neutral"),
    do: "background: var(--ccem-bg-2); color: var(--ccem-fg-muted); border: 1px solid var(--ccem-line);"

  # ---------------------------------------------------------------------------
  # card/1
  # ---------------------------------------------------------------------------

  @doc """
  Renders a surface card with a 1px border and 8px radius.

  ## Options
  - `padded` — when `true` (default), applies 16px inner padding

  ## Examples

      <.card>
        <p>Content here</p>
      </.card>

      <.card padded={false}>
        <table>...</table>
      </.card>
  """
  attr :padded, :boolean, default: true
  attr :rest, :global

  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div
      style={
        "background: var(--ccem-bg-1); border: 1px solid var(--ccem-line); " <>
          "border-radius: 8px; " <>
          if(@padded, do: "padding: 16px;", else: "overflow: hidden;")
      }
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # stat_tile/1
  # ---------------------------------------------------------------------------

  @doc """
  Renders a metric tile with a label, large numeric value, optional delta, and
  an optional sparkline slot.

  ## Examples

      <.stat_tile label="Active Agents" value="42" />

      <.stat_tile label="Token Usage" value="1.2M" delta="+8%" delta_direction="up">
        <:sparkline>
          <canvas id="spark-tokens" phx-hook="Sparkline" data-values="10,20,15,30" />
        </:sparkline>
      </.stat_tile>
  """
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :delta, :string, default: nil
  attr :delta_direction, :string, default: "up", values: ~w(up down flat)
  attr :rest, :global

  slot :sparkline

  def stat_tile(assigns) do
    assigns =
      assign(assigns, delta_color: delta_color(assigns.delta_direction))

    ~H"""
    <div
      style="display: flex; flex-direction: column; gap: 6px;"
      {@rest}
    >
      <span style="font-size: 11px; font-weight: 500; letter-spacing: 0.07em; text-transform: uppercase; color: var(--ccem-fg-dim);">
        {@label}
      </span>
      <span style="font-size: 24px; font-weight: 600; color: var(--ccem-fg); font-variant-numeric: tabular-nums; line-height: 1.1;">
        {@value}
      </span>
      <span :if={@delta} style={"font-size: 12px; font-weight: 500; color: #{@delta_color}; font-variant-numeric: tabular-nums;"}>
        {@delta}
      </span>
      <div :if={@sparkline != []}>
        {render_slot(@sparkline)}
      </div>
    </div>
    """
  end

  defp delta_color("up"), do: "var(--ccem-ok, #22c55e)"
  defp delta_color("down"), do: "var(--ccem-err, #ef4444)"
  defp delta_color("flat"), do: "var(--ccem-fg-muted)"

  # ---------------------------------------------------------------------------
  # segmented_control/1
  # ---------------------------------------------------------------------------

  @doc """
  Renders a horizontal segmented control for switching between named options.

  Pass `on_change` as a Phoenix event name string; the selected value is sent
  as `%{"value" => option}` in the LiveView event payload.

  ## Examples

      <.segmented_control
        options={["Overview", "Logs", "Metrics"]}
        active="Overview"
        on_change="tab_changed"
      />
  """
  attr :options, :list, required: true
  attr :active, :string, required: true
  attr :on_change, :string, default: nil
  attr :rest, :global

  def segmented_control(assigns) do
    ~H"""
    <div
      style="display: inline-flex; align-items: center; gap: 2px; background: var(--ccem-bg-1); border: 1px solid var(--ccem-line); border-radius: 5px; padding: 2px;"
      role="tablist"
      {@rest}
    >
      <button
        :for={option <- @options}
        role="tab"
        aria-selected={to_string(option == @active)}
        phx-click={@on_change}
        phx-value-value={option}
        style={
          "padding: 2px 10px; font-size: 12px; font-weight: 500; border-radius: 3px; " <>
            "border: none; cursor: pointer; transition: background 120ms ease, color 120ms ease; " <>
            if(option == @active,
              do: "background: var(--ccem-bg-2); color: var(--ccem-fg);",
              else: "background: transparent; color: var(--ccem-fg-muted);"
            )
        }
      >
        {option}
      </button>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # toggle/1
  # ---------------------------------------------------------------------------

  @doc """
  Renders a toggle switch (36x20px track, 16px knob).

  The `on_toggle` attribute is the LiveView event name fired on click.
  The event payload is `%{"value" => !current_on}`.

  ## Examples

      <.toggle on={@notifications_enabled} label="Notifications" on_toggle="toggle_notifications" />
  """
  attr :on, :boolean, default: false
  attr :label, :string, default: nil
  attr :on_toggle, :string, default: nil
  attr :rest, :global

  def toggle(assigns) do
    ~H"""
    <label
      style="display: inline-flex; align-items: center; gap: 8px; cursor: pointer; user-select: none;"
      {@rest}
    >
      <button
        type="button"
        role="switch"
        aria-checked={to_string(@on)}
        phx-click={@on_toggle}
        phx-value-value={to_string(!@on)}
        style={
          "position: relative; display: inline-flex; align-items: center; " <>
            "width: 36px; height: 20px; border-radius: 10px; border: none; " <>
            "transition: background 200ms ease; cursor: pointer; flex-shrink: 0; " <>
            if(@on,
              do: "background: var(--ccem-accent);",
              else: "background: var(--ccem-bg-3);"
            )
        }
      >
        <span style={
          "position: absolute; top: 2px; width: 16px; height: 16px; border-radius: 50%; " <>
            "background: var(--ccem-fg-on-accent, #fff); " <>
            "transition: left 200ms ease; box-shadow: 0 1px 3px rgba(0,0,0,0.2); " <>
            if(@on, do: "left: 18px;", else: "left: 2px;")
        } />
      </button>
      <span :if={@label} style="font-size: 13px; color: var(--ccem-fg);">
        {@label}
      </span>
    </label>
    """
  end

  # ---------------------------------------------------------------------------
  # kbd/1
  # ---------------------------------------------------------------------------

  @doc """
  Renders a keyboard shortcut chip.

  ## Examples

      Press <.kbd key="⌘" /> + <.kbd key="K" /> to open the command palette.
      <.kbd key="Escape" />
  """
  attr :key, :string, required: true
  attr :rest, :global

  def kbd(assigns) do
    ~H"""
    <kbd
      style={
        "display: inline-flex; align-items: center; justify-content: center; " <>
          "padding: 1px 5px; min-width: 20px; " <>
          "background: var(--ccem-bg-2); border: 1px solid var(--ccem-line-subtle, var(--ccem-line)); " <>
          "border-bottom-width: 2px; border-radius: 3px; " <>
          "font-family: var(--ccem-font-mono, monospace); font-size: 11px; " <>
          "color: var(--ccem-fg); line-height: 1.4; white-space: nowrap;"
      }
      {@rest}
    >{@key}</kbd>
    """
  end
end
