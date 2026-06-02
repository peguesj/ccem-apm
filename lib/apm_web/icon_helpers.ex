defmodule ApmWeb.IconHelpers do
  @moduledoc """
  SVG sprite icon renderer for the APM v11 design system.

  Implements the custom APM icon set sourced from
  `design-intake/v11.0.0/from-designer/apm-primitives.jsx` (I.* icon set).
  All icons use a 24×24 viewBox, 1.6px stroke, `fill="none"`, `stroke="currentColor"`.

  Icons are served from `priv/static/images/apm-sprite.svg` via `<use href=.../>`.
  This removes all inline SVG from the Elixir module and reduces per-render HTML size.

  `render/2` returns a raw HTML string safe to use with `Phoenix.HTML.raw/1`.

  ## Available icons

  `live`, `search`, `decide`, `tune`, `operate`, `invest`, `bolt`, `spark`,
  `bell`, `agent`, `node`, `chevron`, `arrow`, `plus`, `close`, `x`, `clock`,
  `check`, `ask`, `term`, `doc`, `plug`, `shield`, `grid`, `chat`, `heart`

  Unknown names fall back to a dashed-circle placeholder (sprite `#icon-unknown`).
  """

  @known_icons ~w(
    live search decide tune operate invest bolt spark bell agent node
    chevron arrow plus close x clock check ask term doc plug shield grid
    chat heart
  )

  @spec render(String.t(), pos_integer()) :: String.t()
  def render(name, size \\ 14)

  for icon <- @known_icons do
    def render(unquote(icon), s) do
      s_str = to_string(s)

      ~s(<svg width="#{s_str}" height="#{s_str}" class="apm-icon" aria-hidden="true"><use href="/images/apm-sprite.svg#icon-#{unquote(icon)}"/></svg>)
    end
  end

  # Fallback: unknown icon name → dashed-circle placeholder in sprite
  def render(_unknown, s) do
    s_str = to_string(s)
    ~s(<svg width="#{s_str}" height="#{s_str}" class="apm-icon" aria-hidden="true"><use href="/images/apm-sprite.svg#icon-unknown"/></svg>)
  end
end
