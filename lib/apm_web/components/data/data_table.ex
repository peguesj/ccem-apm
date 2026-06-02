defmodule ApmWeb.Components.Data.DataTable do
  @moduledoc """
  Tier 3 data-display — DataTable.

  Sourced from design-intake/v11.0.0/from-designer/apm-data.jsx (DataTable).
  Requires `:empty`, `:loading`, and `:error` slots by contract (Tier-3 rule).

  Row pseudo-states (pseudo-states.md §Row):
    default   → bg transparent
    hover     → bg var(--apm-surface-overlay)
    active    → bg var(--apm-surface-overlay) + inset 2px 0 0 var(--apm-accent) box-shadow
    selected  → bg var(--apm-accent-soft) + inset 2px 0 0 var(--apm-accent)
  Transition: background 120ms var(--apm-ease-out).

  Header: sticky top 0, bg surface-raised, zIndex 1, class `apm-upper`,
    fontSize 10, fontWeight 500, color text-dim, letterSpacing 0.08em.

  Density:
    compact     → padY 6px
    comfortable → padY 11px
    default     → padY 8px

  `:col` slots declare columns. Each col slot should expose `key`, `label`,
  `align` (default "left"), `mono`, `wrap` inner attrs. Callers provide the
  cell content via the slot's inner_block with `let={row}` binding.

  `keyboard_nav` enables the TableKeyNav hook (CP-310, already shipped).

  ## JS hook
  # TODO: colocate data/data_table.hook.js — TableKeyNav (CP-310 reference)
  # phx-hook="TableKeyNav" applied to table wrapper when keyboard_nav is true.

  ## Spec reference
  - Component map: handoff-claude-code/02-COMPONENT-MAP.md
  - JSX source: apm-data.jsx → DataTable
  - Pseudo-state matrix: pseudo-states.md §Row (DataTable)
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :rows, :list, default: []
  attr :is_loading, :boolean, default: false
  attr :error_message, :string, default: nil
  attr :density, :string, default: "default", values: ~w(compact default comfortable)
  attr :keyboard_nav, :boolean, default: false
  attr :selected_row, :any, default: nil
  attr :on_row_click, :string, default: nil
  attr :rest, :global

  slot :col, required: true do
    attr :key, :string
    attr :label, :string
    attr :align, :string
    attr :mono, :boolean
    attr :wrap, :boolean
    attr :width, :string
  end

  slot :empty, required: true
  slot :loading, required: true
  slot :error, required: true

  def data_table(assigns) do
    ~H"""
    <%= cond do %>
      <% @is_loading -> %>
        <%= render_slot(@loading) %>
      <% @error_message -> %>
        <%= render_slot(@error) %>
      <% @rows == [] -> %>
        <%= render_slot(@empty) %>
      <% true -> %>
        <div
          id={@id}
          class={["apm-data-table", "apm-data-table--density-#{@density}", "apm-focusable"]}
          tabindex={if @keyboard_nav, do: "0", else: nil}
          phx-hook={if @keyboard_nav, do: "TableKeyNav", else: nil}
          role="grid"
          {@rest}
        >
          <table class="apm-data-table__table">
            <thead>
              <tr>
                <%= for col <- @col do %>
                  <th
                    class="apm-data-table__th apm-upper"
                    style={"text-align:#{col[:align] || "left"};width:#{col[:width]}"}
                  >
                    {col[:label]}
                  </th>
                <% end %>
              </tr>
            </thead>
            <tbody>
              <%= for {row, i} <- Enum.with_index(@rows) do %>
                <tr
                  id={"#{@id}-row-#{i}"}
                  class={[
                    "apm-data-table__row",
                    @selected_row == (row[:id] || i) && "apm-data-table__row--selected",
                    @on_row_click && "apm-data-table__row--clickable"
                  ]}
                  phx-click={@on_row_click}
                  phx-value-index={i}
                >
                  <%= for col <- @col do %>
                    <td
                      class={[
                        "apm-data-table__td",
                        col[:mono] && "apm-mono apm-tabular"
                      ]}
                      style={"text-align:#{col[:align] || "left"}"}
                    >
                      <%= render_slot(col, row) %>
                    </td>
                  <% end %>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
    <% end %>
    """
  end
end
