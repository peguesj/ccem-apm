defmodule ApmWeb.IconHelpers do
  @moduledoc """
  Inline SVG icon renderer for the APM v11 design system.

  Implements the custom APM icon set sourced from
  `design-intake/v11.0.0/from-designer/apm-primitives.jsx` (I.* icon set).
  All icons use a 24×24 viewBox, 1.6px stroke, `fill="none"`, `stroke="currentColor"`.

  `render/2` returns a raw HTML string safe to use with `Phoenix.HTML.raw/1`.

  The function is intentionally a simple map lookup + fallback so that:
  - Phase 3 can replace the body with a sprite reference without changing callers.
  - Compile-time clause dispatch (guards on binary) keeps it fast.

  TODO (Phase 3): replace body with
  `<use href="/images/apm-sprite.svg#" <> name <> "\" width=\"" <> size <> "\" height=\"" <> size <> "\"/>`
  once sprite generation is added to the asset pipeline.
  """

  @spec render(String.t(), pos_integer()) :: String.t()
  def render(name, size \\ 14)

  def render("live", s),
    do: svg(s, ~s|<circle cx="12" cy="12" r="3"/><path d="M5.6 5.6a9 9 0 0 0 0 12.8M18.4 5.6a9 9 0 0 1 0 12.8M8.5 8.5a5 5 0 0 0 0 7M15.5 8.5a5 5 0 0 1 0 7"/>|)

  def render("search", s),
    do: svg(s, ~s|<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>|)

  def render("decide", s),
    do: svg(s, ~s|<path d="M12 2v10l6 3M12 22a10 10 0 1 1 0-20 10 10 0 0 1 0 20z"/>|)

  def render("tune", s),
    do: svg(s, ~s|<path d="M4 6h16M4 12h10M4 18h7"/><circle cx="18" cy="12" r="2.5"/>|)

  def render("operate", s),
    do: svg(s, ~s|<circle cx="12" cy="12" r="3"/><path d="M19.07 4.93a10 10 0 1 1-14.14 0"/>|)

  def render("invest", s),
    do: svg(s, ~s|<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5M11 8v3l2 2"/>|)

  def render("bolt", s),
    do: svg(s, ~s|<path d="M13 2 4.09 12.6H12l-1 9.4 8.91-10.6H12L13 2z"/>|)

  def render("spark", s),
    do: svg(s, ~s|<path d="m12 2 2.4 7.4H22l-6.2 4.5 2.4 7.4L12 17l-6.2 4.3 2.4-7.4L2 9.4h7.6z"/>|)

  def render("bell", s),
    do: svg(s, ~s|<path d="M6 8a6 6 0 0 1 12 0c0 7 3 8 3 8H3s3-1 3-8M10 21a2 2 0 0 0 4 0"/>|)

  def render("agent", s),
    do: svg(s, ~s|<rect x="3" y="3" width="18" height="14" rx="2"/><path d="M8 21h8M12 17v4"/>|)

  def render("node", s),
    do: svg(s, ~s|<circle cx="12" cy="12" r="4"/><circle cx="4" cy="6" r="2"/><circle cx="20" cy="6" r="2"/><circle cx="4" cy="18" r="2"/><circle cx="20" cy="18" r="2"/><path d="M6 7.5 10 10M14 10l4-2.5M6 16.5 10 14M14 14l4 2.5"/>|)

  def render("chevron", s),
    do: svg(s, ~s|<path d="m9 6 6 6-6 6"/>|)

  def render("arrow", s),
    do: svg(s, ~s|<path d="M5 12h14M13 6l6 6-6 6"/>|)

  def render("plus", s),
    do: svg(s, ~s|<path d="M12 5v14M5 12h14"/>|)

  def render("close", s),
    do: svg(s, ~s|<path d="m6 6 12 12M18 6 6 18"/>|)

  def render("x", s),
    do: svg(s, ~s|<path d="m6 6 12 12M18 6 6 18"/>|)

  def render("clock", s),
    do: svg(s, ~s|<circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/>|)

  def render("check", s),
    do: svg(s, ~s|<path d="m5 12 5 5L20 6"/>|)

  def render("ask", s),
    do: svg(s, ~s|<circle cx="12" cy="12" r="10"/><path d="M9.1 9a3 3 0 0 1 5.8 1c0 2-3 3-3 3M12 17h.01"/>|)

  def render("term", s),
    do: svg(s, ~s|<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M7 8l4 4-4 4M13 16h4"/>|)

  def render("doc", s),
    do: svg(s, ~s|<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="8" y1="13" x2="16" y2="13"/><line x1="8" y1="17" x2="16" y2="17"/>|)

  def render("plug", s),
    do: svg(s, ~s|<path d="M18.4 5.6a9 9 0 0 1 0 12.8M5.6 5.6a9 9 0 0 0 0 12.8M9 9v6M15 9v6"/>|)

  def render("shield", s),
    do: svg(s, ~s|<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>|)

  def render("grid", s),
    do: svg(s, ~s|<rect x="4" y="4" width="7" height="7" rx="1"/><rect x="13" y="4" width="7" height="7" rx="1"/><rect x="4" y="13" width="7" height="7" rx="1"/><rect x="13" y="13" width="7" height="7" rx="1"/>|)

  def render("chat", s),
    do: svg(s, ~s|<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>|)

  def render("heart", s),
    do: svg(s, ~s|<path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/>|)

  # Fallback: empty circle placeholder for unrecognised names
  def render(_unknown, s),
    do: svg(s, ~s|<circle cx="12" cy="12" r="5" stroke-dasharray="2 3"/>|)

  # ── Private ─────────────────────────────────────────────────────────────────

  defp svg(size, paths) do
    ~s|<svg width="#{size}" height="#{size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">#{paths}</svg>|
  end
end
