defmodule ApmV5Web.Components.AiComponents do
  @moduledoc """
  AI-native UI components for the CCEM APM dashboard.

  All components are pure function components (no LiveComponent state) that
  reference `--ccem-*` CSS custom properties defined in `assets/css/app.css`.
  Utility animation classes (`ccem-shimmer`, `ccem-pulse`, `ccem-caret`,
  `ccem-scanline`, `ccem-waveform`) are expected to be present in app.css.

  ## Usage

      import ApmV5Web.Components.AiComponents

      <.sparkline data={[10, 40, 25, 60, 45, 80]} live_dot />
      <.streaming_text text={@partial_output} streaming={@streaming} />
      <.skeleton lines={3} />
      <.waveform active={@processing} />
      <.gauge value={72} label="CPU" />
      <.presence_stack users={@online_users} />
      <.agent_card agent_id={@id} name={@name} role="orchestrator" status="active">
        <:activity><.sparkline data={@history} /></:activity>
      </.agent_card>
  """

  use Phoenix.Component
  import ApmV5Web.Components.DesignSystem, only: [badge: 1]

  # ---------------------------------------------------------------------------
  # sparkline/1
  # ---------------------------------------------------------------------------

  @doc """
  Renders a minimal SVG polyline sparkline — no axes, no labels.

  The data list is normalized to fit the component's `width` × `height` viewport.
  When `live_dot` is `true`, a pulsing circle is rendered at the last data point.

  ## Attributes

  - `data`     (required) — list of numeric values
  - `width`    — SVG width in px (default 80)
  - `height`   — SVG height in px (default 24)
  - `color`    — stroke color; accepts any CSS value (default `var(--ccem-accent)`)
  - `live_dot` — whether to render an animated dot at the last point (default false)
  """
  attr :data, :list, required: true
  attr :width, :integer, default: 80
  attr :height, :integer, default: 24
  attr :color, :string, default: "var(--ccem-accent)"
  attr :live_dot, :boolean, default: false
  attr :rest, :global

  def sparkline(assigns) do
    assigns = assign(assigns, :points_str, sparkline_points(assigns.data, assigns.width, assigns.height))
    assigns = assign(assigns, :last_point, sparkline_last(assigns.data, assigns.width, assigns.height))

    ~H"""
    <svg
      width={@width}
      height={@height}
      viewBox={"0 0 #{@width} #{@height}"}
      xmlns="http://www.w3.org/2000/svg"
      style="overflow: visible; display: inline-block; vertical-align: middle;"
      {@rest}
    >
      <polyline
        points={@points_str}
        fill="none"
        stroke={@color}
        stroke-width="1.5"
        stroke-linejoin="round"
        stroke-linecap="round"
      />
      <%= if @live_dot && @last_point do %>
        <% {lx, ly} = @last_point %>
        <circle cx={lx} cy={ly} r="3.5" fill={@color} opacity="0.35" class="ccem-pulse" />
        <circle cx={lx} cy={ly} r="2" fill={@color} />
      <% end %>
    </svg>
    """
  end

  # Normalize data to polyline points string.
  @spec sparkline_points(list(), integer(), integer()) :: String.t()
  defp sparkline_points(data, _width, _height) when length(data) < 2, do: ""

  defp sparkline_points(data, width, height) do
    min = Enum.min(data)
    max = Enum.max(data)
    range = if max == min, do: 1, else: max - min

    pad = 2
    usable_w = width - pad * 2
    usable_h = height - pad * 2
    n = length(data) - 1

    data
    |> Enum.with_index()
    |> Enum.map(fn {v, i} ->
      x = pad + i / n * usable_w
      y = pad + usable_h - (v - min) / range * usable_h
      "#{Float.round(x, 2)},#{Float.round(y, 2)}"
    end)
    |> Enum.join(" ")
  end

  @spec sparkline_last(list(), integer(), integer()) :: {float(), float()} | nil
  defp sparkline_last(data, _width, _height) when length(data) < 2, do: nil

  defp sparkline_last(data, width, height) do
    min = Enum.min(data)
    max = Enum.max(data)
    range = if max == min, do: 1, else: max - min
    pad = 2
    usable_h = height - pad * 2
    last_v = List.last(data)
    x = width - pad |> Kernel.-(0.0)
    y = pad + usable_h - (last_v - min) / range * usable_h
    {x, y}
  end

  # ---------------------------------------------------------------------------
  # streaming_text/1
  # ---------------------------------------------------------------------------

  @doc """
  Renders text with an optional blinking caret for streaming token output.

  Set `streaming` to `true` while new tokens are arriving; the caret will
  blink via the `.ccem-caret` CSS animation and disappear once `streaming`
  is set to `false`.

  ## Attributes

  - `text`      — the string to display (default "")
  - `streaming` — whether to show the blinking caret (default false)
  - `class`     — additional CSS classes applied to the outer span
  """
  attr :text, :string, default: ""
  attr :streaming, :boolean, default: false
  attr :class, :string, default: nil

  def streaming_text(assigns) do
    ~H"""
    <span class={["font-mono text-sm", @class]} style="color: var(--ccem-fg);">
      {@text}<%= if @streaming do %><span class="ccem-caret" aria-hidden="true"></span><% end %>
    </span>
    """
  end

  # ---------------------------------------------------------------------------
  # skeleton/1
  # ---------------------------------------------------------------------------

  @doc """
  Renders a shimmer placeholder for content that has not yet loaded.

  When `lines` is greater than 1, renders N separate bars with a small gap
  between them. The last bar in a multi-line skeleton is narrowed to 60% to
  mimic a natural paragraph ending.

  ## Attributes

  - `width`  — CSS width value for each bar (default "100%")
  - `height` — CSS height value for each bar (default "16px")
  - `lines`  — number of bars to render (default 1)
  - `class`  — additional CSS classes on the wrapper element
  """
  attr :width, :string, default: "100%"
  attr :height, :string, default: "16px"
  attr :lines, :integer, default: 1
  attr :class, :string, default: nil

  def skeleton(assigns) do
    ~H"""
    <div class={["flex flex-col gap-2", @class]} role="status" aria-label="Loading">
      <%= for i <- 1..@lines do %>
        <div
          class="ccem-shimmer rounded"
          style={"width: #{if i == @lines && @lines > 1, do: "60%", else: @width}; height: #{@height};"}
        />
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # waveform/1
  # ---------------------------------------------------------------------------

  @doc """
  Renders five animated vertical bars that mimic a voice/processing waveform.

  Bars animate with staggered delays using the `ccem-waveform` keyframe defined
  in `app.css`. When `active` is `false` the bars are frozen at mid-height.

  ## Attributes

  - `active` — whether the animation is running (default true)
  - `color`  — bar fill color; any CSS value (default `var(--ccem-accent)`)
  """
  attr :active, :boolean, default: true
  attr :color, :string, default: "var(--ccem-accent)"
  attr :rest, :global

  def waveform(assigns) do
    ~H"""
    <span
      style="display: inline-flex; align-items: center; gap: 2px; height: 16px;"
      aria-label="Processing"
      {@rest}
    >
      <%= for delay <- ["0ms", "160ms", "320ms", "160ms", "0ms"] do %>
        <span style={[
          "display: inline-block;",
          "width: 3px;",
          "height: 16px;",
          "border-radius: 2px;",
          "background: #{@color};",
          "transform-origin: center bottom;",
          if(@active,
            do: "animation: ccem-waveform 0.9s ease-in-out #{delay} infinite;",
            else: "transform: scaleY(0.4); opacity: 0.45;"
          )
        ]} />
      <% end %>
    </span>
    """
  end

  # ---------------------------------------------------------------------------
  # gauge/1
  # ---------------------------------------------------------------------------

  @doc """
  Renders a radial SVG gauge using a 3/4 arc (270°) to display 0-100% values.

  The track is rendered in `--ccem-bg-3` and the fill color shifts based on
  thresholds: ok (< 70), warn (70-89), err (>= 90). The value is shown as
  a centered mono text label.

  ## Attributes

  - `value` — integer 0-100 (default 0)
  - `size`  — bounding box size in px; SVG is square (default 60)
  - `label` — optional sub-label below the value
  """
  attr :value, :integer, default: 0
  attr :size, :integer, default: 60
  attr :label, :string, default: nil
  attr :rest, :global

  def gauge(assigns) do
    # Arc geometry: 270° arc, starting at 135° (bottom-left), sweeping clockwise.
    r = (assigns.size / 2 - 6) |> Float.round(2)
    cx = assigns.size / 2
    cy = assigns.size / 2
    circumference = 2 * :math.pi() * r
    # 270° = 3/4 of a full circle
    arc_len = circumference * 0.75
    clamped = min(max(assigns.value, 0), 100)
    fill_len = arc_len * clamped / 100
    gap_len = circumference - fill_len

    color =
      cond do
        clamped >= 90 -> "var(--ccem-err)"
        clamped >= 70 -> "var(--ccem-warn)"
        true -> "var(--ccem-ok)"
      end

    # Start angle is 135° from 3 o'clock (i.e., lower-left).
    # stroke-dashoffset rotates so the arc starts at 135°.
    # The gap is the remaining 25% of the circle plus unused fill.
    rotation = 135
    offset = circumference * (1 - 0.75)

    assigns =
      assigns
      |> assign(:r, r)
      |> assign(:cx, cx)
      |> assign(:cy, cy)
      |> assign(:circumference, circumference)
      |> assign(:arc_len, arc_len)
      |> assign(:fill_len, fill_len)
      |> assign(:gap_len, gap_len)
      |> assign(:color, color)
      |> assign(:rotation, rotation)
      |> assign(:offset, offset)
      |> assign(:clamped, clamped)

    ~H"""
    <svg
      width={@size}
      height={@size}
      viewBox={"0 0 #{@size} #{@size}"}
      xmlns="http://www.w3.org/2000/svg"
      {@rest}
    >
      <%!-- Track arc --%>
      <circle
        cx={@cx}
        cy={@cy}
        r={@r}
        fill="none"
        stroke="var(--ccem-bg-3)"
        stroke-width="5"
        stroke-dasharray={"#{Float.round(@arc_len, 2)} #{Float.round(@circumference - @arc_len, 2)}"}
        stroke-dashoffset={Float.round(@offset, 2)}
        transform={"rotate(#{@rotation}, #{@cx}, #{@cy})"}
        stroke-linecap="round"
      />
      <%!-- Fill arc --%>
      <circle
        cx={@cx}
        cy={@cy}
        r={@r}
        fill="none"
        stroke={@color}
        stroke-width="5"
        stroke-dasharray={"#{Float.round(@fill_len, 2)} #{Float.round(@gap_len + (@circumference - @arc_len), 2)}"}
        stroke-dashoffset={Float.round(@offset, 2)}
        transform={"rotate(#{@rotation}, #{@cx}, #{@cy})"}
        stroke-linecap="round"
      />
      <%!-- Center value --%>
      <text
        x={@cx}
        y={@cy}
        text-anchor="middle"
        dominant-baseline="central"
        font-family="'Geist Mono', monospace"
        font-size={round(@size * 0.22)}
        fill="var(--ccem-fg)"
      >{@clamped}</text>
      <%= if @label do %>
        <text
          x={@cx}
          y={@cy + @size * 0.18}
          text-anchor="middle"
          dominant-baseline="central"
          font-family="'Geist', sans-serif"
          font-size={round(@size * 0.14)}
          fill="var(--ccem-fg-muted)"
        >{@label}</text>
      <% end %>
    </svg>
    """
  end

  # ---------------------------------------------------------------------------
  # presence_stack/1
  # ---------------------------------------------------------------------------

  @doc """
  Renders a horizontal stack of overlapping user avatar circles.

  Each circle shows the user's initials derived from their `name`. Circles
  beyond `max` are collapsed into a "+N" overflow badge. Status is indicated
  by a small dot: `"active"` → accent, `"idle"` → dim.

  ## Attributes

  - `users` (required) — list of maps with `:name` and `:status` keys
  - `max`              — maximum circles before overflow badge (default 4)
  """
  attr :users, :list, required: true
  attr :max, :integer, default: 4
  attr :rest, :global

  def presence_stack(assigns) do
    visible = Enum.take(assigns.users, assigns.max)
    overflow = max(length(assigns.users) - assigns.max, 0)
    assigns = assigns |> assign(:visible, visible) |> assign(:overflow, overflow)

    ~H"""
    <div style="display: inline-flex; align-items: center;" {@rest}>
      <%= for {user, idx} <- Enum.with_index(@visible) do %>
        <div
          title={user.name}
          style={[
            "position: relative;",
            "width: 28px; height: 28px;",
            "border-radius: 50%;",
            "background: var(--ccem-bg-2);",
            "border: 2px solid var(--ccem-bg-0);",
            "display: flex; align-items: center; justify-content: center;",
            "font-family: 'Geist', sans-serif; font-size: 10px; font-weight: 500;",
            "color: var(--ccem-fg-muted);",
            "flex-shrink: 0;",
            if(idx > 0, do: "margin-left: -8px;", else: "")
          ]}
        >
          {initials(user.name)}
          <span style={[
            "position: absolute; bottom: 0; right: 0;",
            "width: 7px; height: 7px; border-radius: 50%;",
            "border: 1.5px solid var(--ccem-bg-0);",
            "background: #{if user[:status] == "active", do: "var(--ccem-accent)", else: "var(--ccem-fg-faint)"};",
          ]} />
        </div>
      <% end %>
      <%= if @overflow > 0 do %>
        <div style={[
          "width: 28px; height: 28px; border-radius: 50%;",
          "background: var(--ccem-bg-3);",
          "border: 2px solid var(--ccem-bg-0);",
          "display: flex; align-items: center; justify-content: center;",
          "font-family: 'Geist Mono', monospace; font-size: 9px;",
          "color: var(--ccem-fg-dim);",
          "flex-shrink: 0; margin-left: -8px;",
        ]}>
          +{@overflow}
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # agent_card/1
  # ---------------------------------------------------------------------------

  @doc """
  Renders a compact agent identity card with identicon, name, role, and status.

  An optional `activity` slot accepts any inline visualization (e.g., `<.sparkline>`).
  The identicon is a deterministic 5×5 SVG grid generated from the `agent_id` hash.

  ## Attributes

  - `agent_id` (required) — unique identifier used for identicon generation
  - `name`     (required) — display name of the agent
  - `role`                — agent role label (default nil)
  - `status`              — one of "active", "idle", "error", "done" (default "idle")

  ## Slots

  - `activity` — optional inline visualization (e.g., a sparkline)
  """
  attr :agent_id, :string, required: true
  attr :name, :string, required: true
  attr :role, :string, default: nil
  attr :status, :string, default: "idle"
  slot :activity

  attr :rest, :global

  def agent_card(assigns) do
    assigns = assign(assigns, :identicon_cells, identicon_cells(assigns.agent_id))

    ~H"""
    <div
      style={[
        "width: 200px;",
        "padding: 12px;",
        "border-radius: 8px;",
        "background: var(--ccem-bg-1);",
        "border: 1px solid var(--ccem-line-subtle);",
        "display: flex; flex-direction: column; gap: 8px;",
      ]}
      {@rest}
    >
      <div style="display: flex; align-items: center; gap: 8px;">
        <%!-- Identicon --%>
        <svg width="28" height="28" viewBox="0 0 5 5" xmlns="http://www.w3.org/2000/svg"
             style="border-radius: 4px; flex-shrink: 0; background: var(--ccem-bg-2);">
          <%= for {row, col, on} <- @identicon_cells do %>
            <%= if on do %>
              <rect x={col} y={row} width="1" height="1" fill="var(--ccem-accent)" opacity="0.9" />
            <% end %>
          <% end %>
        </svg>
        <%!-- Name / role --%>
        <div style="flex: 1; min-width: 0;">
          <div style="font-family: 'Geist', sans-serif; font-size: 12px; font-weight: 500; color: var(--ccem-fg); white-space: nowrap; overflow: hidden; text-overflow: ellipsis;">
            {@name}
          </div>
          <%= if @role do %>
            <div style="font-family: 'Geist Mono', monospace; font-size: 10px; color: var(--ccem-fg-dim); margin-top: 1px;">
              {@role}
            </div>
          <% end %>
        </div>
      </div>
      <%!-- Status badge --%>
      <div>
        <.badge tone={status_tone(@status)} dot>{String.capitalize(@status)}</.badge>
      </div>
      <%!-- Activity slot --%>
      <%= if @activity != [] do %>
        <div style="border-top: 1px solid var(--ccem-line-subtle); padding-top: 8px;">
          {render_slot(@activity)}
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Derive two-character initials from a name string.
  @spec initials(String.t()) :: String.t()
  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.map(&String.upcase/1)
    |> Enum.join()
  end

  # Map agent status to DesignSystem badge tone.
  @spec status_tone(String.t()) :: String.t()
  defp status_tone("active"), do: "ok"
  defp status_tone("error"), do: "err"
  defp status_tone("done"), do: "iris"
  defp status_tone(_), do: "neutral"

  # Generate a symmetric 5×5 identicon from a hash of agent_id.
  # Returns a list of {row, col, boolean} tuples for SVG rect rendering.
  # Only the left 3 columns are generated; the right 2 mirror them.
  @spec identicon_cells(String.t()) :: list({integer(), integer(), boolean()})
  defp identicon_cells(agent_id) do
    hash =
      :crypto.hash(:sha256, agent_id)
      |> :binary.bin_to_list()

    for row <- 0..4, col <- 0..4 do
      # Mirror: columns 3 and 4 mirror columns 1 and 0 respectively.
      source_col = if col >= 3, do: 4 - col, else: col
      byte_index = rem(row * 3 + source_col, length(hash))
      on = Enum.at(hash, byte_index) > 127
      {row, col, on}
    end
  end

  @doc """
  Micro bar chart for token distribution or activity histograms.

  Renders an inline SVG bar chart from a list of data points. Each bar's height
  is proportional to its value relative to the maximum value in the dataset.
  Supports per-bar color overrides and optional CSS transition animation.

  ## Attributes

    * `:data` - Required. List of maps with keys:
      * `:value` - numeric bar height value (required per entry)
      * `:label` - optional string label (unused in SVG, for caller reference)
      * `:color` - optional CSS color string (e.g. `"var(--ccem-accent)"`); falls back to `var(--ccem-accent)`
    * `:height` - SVG height in pixels. Defaults to `32`.
    * `:bar_width` - Width of each bar in pixels. Defaults to `10`.
    * `:gap` - Gap between bars in pixels. Defaults to `2`.
    * `:animated` - When `true`, adds `ccem-bars-animated` class for CSS animation. Defaults to `false`.
    * `:class` - Additional CSS classes. Defaults to `nil`.
    * `:rest` - Global HTML attributes forwarded to the `<svg>` element.

  ## Examples

      <.bars data={[%{value: 10}, %{value: 40}, %{value: 25}]} />

      <.bars
        data={[%{value: 80, color: "var(--ccem-success)"}, %{value: 20}]}
        height={48}
        bar_width={12}
        gap={3}
        animated={true}
      />
  """
  @spec bars(Phoenix.LiveView.Socket.assigns()) :: Phoenix.LiveView.Rendered.t()
  attr :data, :list, required: true
  attr :height, :integer, default: 32
  attr :bar_width, :integer, default: 10
  attr :gap, :integer, default: 2
  attr :animated, :boolean, default: false
  attr :class, :string, default: nil
  attr :rest, :global

  def bars(assigns) do
    bar_count = length(assigns.data)
    total_width = bar_count * (assigns.bar_width + assigns.gap) - assigns.gap
    max_val = assigns.data |> Enum.map(& &1.value) |> Enum.max(fn -> 1 end)

    assigns =
      assigns
      |> assign(:total_width, total_width)
      |> assign(:max_val, max_val)

    ~H"""
    <svg
      viewBox={"0 0 #{@total_width} #{@height}"}
      width={@total_width}
      height={@height}
      class={["ccem-bars", @animated && "ccem-bars-animated", @class]}
      {@rest}
    >
      <%= for {item, idx} <- Enum.with_index(@data) do %>
        <rect
          x={idx * (@bar_width + @gap)}
          y={@height - round(item.value / @max_val * @height)}
          width={@bar_width}
          height={round(item.value / @max_val * @height)}
          rx="2"
          fill={item[:color] || "var(--ccem-accent)"}
          style={"transition: height var(--ccem-dur-base) var(--ccem-ease-out), y var(--ccem-dur-base) var(--ccem-ease-out)"}
        />
      <% end %>
    </svg>
    """
  end
end
