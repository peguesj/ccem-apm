defmodule ApmV5Web.Components.Data.StreamingText do
  @moduledoc """
  Tier 3 data-display — StreamingText (character-by-character reveal with caret).

  Sourced from design-intake/v11.0.0/from-designer/apm-data.jsx (StreamingText).

  Client-side streaming is handled by the StreamingCaret JS hook. The server sends
  the full `text` string; the hook reveals it character-by-character at `speed` ms
  intervals. A blinking caret (class `apm-caret`) appears after the last revealed
  character until streaming completes.

  Reduce-motion: text appears whole, no caret (motion.md §Loading patterns).

  `phx-update="ignore"` prevents LiveView from overwriting the hook's DOM mutations.
  The hook should emit a `streaming_done` JS event when all characters are revealed.

  ## JS hook
  # TODO: colocate data/streaming_text.hook.js — StreamingCaret hook (caret blink)
  # phx-hook="StreamingCaret" — reads data-text and data-speed attrs.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-data.jsx → StreamingText
  - Motion spec: motion.md §Loading patterns → Streaming text (AG-UI, ⌘K AI)
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :speed, :integer, default: 22
  attr :caret, :boolean, default: true
  attr :rest, :global

  slot :inner_block

  def streaming_text(assigns) do
    ~H"""
    <span
      id={@id}
      class="apm-streaming-text"
      phx-hook="StreamingCaret"
      phx-update="ignore"
      data-text={@text}
      data-speed={@speed}
      data-caret={to_string(@caret)}
      {@rest}
    >
      <%!-- Hook populates this span progressively. Initial render shows full text
           as fallback for SSR / reduce-motion / no-JS environments. --%>
      {@text}
    </span>
    """
  end
end
