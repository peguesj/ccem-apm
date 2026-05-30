defmodule ApmWeb.Components.Data.JsonViewer do
  @moduledoc """
  Tier 3 data-display — JsonViewer (syntax-highlighted JSON tree).

  Sourced from design-intake/v11.0.0/from-designer/apm-data.jsx (JsonViewer).

  Container: class `apm-mono`, fontSize 11.5, lineHeight 1.7, color text-primary,
    bg var(--apm-surface-sunken), borderRadius var(--apm-r-md), padding 12px,
    overflow auto.

  Color coding (CSS classes, mirrors the JSX render function):
    null    → apm-json--null     (color: text-faint)
    boolean → apm-json--bool     (color: decoration-iris)
    number  → apm-json--number   (color: status-info)
    string  → apm-json--string   (color: accent-dim)
    key     → apm-json--key      (color: text-muted)

  `data` accepts any Elixir term that `Jason.encode!/1` can encode.
  The tree is pre-rendered server-side as nested HTML spans. Indentation
  is achieved via `margin-left: {depth * 14}px` per depth level.

  For large payloads (> 50 keys at root), consider passing a pre-truncated
  map and appending a `… {n} more` string.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-data.jsx → JsonViewer
  """
  use Phoenix.Component

  attr :data, :any, required: true
  attr :rest, :global

  def json_viewer(assigns) do
    ~H"""
    <div class="apm-json-viewer apm-mono" {@rest}>
      <%= render_json_value(@data, 0) %>
    </div>
    """
  end

  defp render_json_value(nil, _depth) do
    Phoenix.HTML.raw(~s(<span class="apm-json--null">null</span>))
  end

  defp render_json_value(v, _depth) when is_boolean(v) do
    Phoenix.HTML.raw(~s(<span class="apm-json--bool">#{v}</span>))
  end

  defp render_json_value(v, _depth) when is_number(v) do
    Phoenix.HTML.raw(~s(<span class="apm-json--number">#{v}</span>))
  end

  defp render_json_value(v, _depth) when is_binary(v) do
    escaped = Phoenix.HTML.html_escape(v)
    Phoenix.HTML.raw(~s(<span class="apm-json--string">"#{escaped}"</span>))
  end

  defp render_json_value(list, depth) when is_list(list) do
    items =
      list
      |> Enum.with_index()
      |> Enum.map(fn {item, i} ->
        comma = if i < length(list) - 1, do: ",", else: ""
        ~s(<div style="margin-left:#{(depth + 1) * 14}px">#{Phoenix.HTML.safe_to_string(render_json_value(item, depth + 1))}#{comma}</div>)
      end)
      |> Enum.join("")

    Phoenix.HTML.raw("[#{items}]")
  end

  defp render_json_value(map, depth) when is_map(map) do
    entries = Map.to_list(map)
    n = length(entries)

    items =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {{k, v}, i} ->
        comma = if i < n - 1, do: ",", else: ""
        key_html = ~s(<span class="apm-json--key">#{Phoenix.HTML.html_escape(to_string(k))}</span>)
        val_html = Phoenix.HTML.safe_to_string(render_json_value(v, depth + 1))
        ~s(<div style="margin-left:#{(depth + 1) * 14}px">#{key_html}: #{val_html}#{comma}</div>)
      end)
      |> Enum.join("")

    Phoenix.HTML.raw("{#{items}}")
  end
end
