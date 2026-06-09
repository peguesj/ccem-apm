defmodule ApmWeb.DrtwLive do
  @moduledoc """
  LiveView for the DRTW (Don't Reinvent The Wheel) discovery framework.
  Surfaces existing solutions and patterns before writing custom code.
  Checks L1–L5 layers before recommending novel implementation.
  """

  use ApmWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "DRTW",
       sidebar_collapsed: false,
       inspector_open: false,
       search: "",
       results: [],
       selected: nil,
       layers: ["L1 Packages", "L2 Platform", "L3 Skills", "L4 Community", "L5 Patterns"],
       active_layer: "L1 Packages"
     )
     |> ApmWeb.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  @impl true
  def handle_event("search", %{"value" => q}, socket) do
    results = find_solutions(q)
    {:noreply, assign(socket, search: q, results: results, selected: nil)}
  end

  def handle_event("set_layer", %{"value" => layer}, socket) do
    {:noreply, assign(socket, active_layer: layer)}
  end

  def handle_event("select_result", %{"id" => id}, socket) do
    selected = find_by_id(socket.assigns.results, id)
    {:noreply, assign(socket, selected: selected, inspector_open: selected != nil)}
  end

  # -- Render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar><.sidebar_nav current_path="/drtw" /></:sidebar>
      <:topbar><.top_bar project_name="CCEM APM" /></:topbar>
      <:main>
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
          <div style="display: flex; align-items: center; gap: 10px;">
            <h1 style="margin: 0; font-size: 16px; font-weight: 600; color: var(--ccem-fg);">DRTW</h1>
            <.badge tone="neutral">Discovery Framework</.badge>
          </div>
        </div>

        <div style="margin-bottom: 16px;">
          <.ds_input
            type="search"
            placeholder="Search packages, skills, patterns..."
            value={@search}
            name="search"
            phx-change="search"
            phx-debounce="300"
          />
        </div>

        <div style="margin-bottom: 16px;">
          <.segmented_control
            options={@layers}
            active={@active_layer}
            on_change="set_layer"
          />
        </div>

        <div style="margin-bottom: 12px;">
          <div style="display: flex; gap: 12px;">
            <.card padded={false} style="flex: 1; padding: 12px 16px;">
              <.stat_tile label="Results" value={to_string(length(@results))} />
            </.card>
            <.card padded={false} style="flex: 1; padding: 12px 16px;">
              <.stat_tile label="Active Layer" value={@active_layer} />
            </.card>
            <.card padded={false} style="flex: 1; padding: 12px 16px;">
              <.stat_tile label="Search" value={if @search == "", do: "—", else: @search} />
            </.card>
          </div>
        </div>

        <.card padded={false}>
          <div :if={@results == [] and @search == ""} style="padding: 48px 24px; text-align: center;">
            <p style="font-size: 13px; color: var(--ccem-fg-muted); margin: 0 0 6px 0;">
              Enter a search term to discover existing solutions.
            </p>
            <p style="font-size: 11px; color: var(--ccem-fg-muted); margin: 0;">
              Check L1–L5 layers before writing custom code.
            </p>
          </div>
          <div :if={@results == [] and @search != ""} style="padding: 48px 24px; text-align: center;">
            <p style="font-size: 13px; color: var(--ccem-fg-muted); margin: 0;">
              No results found for "{@search}". Consider L6 custom implementation.
            </p>
          </div>
          <.data_table :if={@results != []} id="drtw-results-table" rows={@results}>
            <:col :let={row} label="Name">
              <span style="font-size: 13px; font-weight: 500; color: var(--ccem-fg);">
                {row[:name]}
              </span>
            </:col>
            <:col :let={row} label="Type">
              <.badge tone={result_type_tone(row[:type])}>{row[:type]}</.badge>
            </:col>
            <:col :let={row} label="Source">
              <span style="font-size: 12px; font-family: monospace; color: var(--ccem-fg-muted);">
                {row[:source]}
              </span>
            </:col>
            <:col :let={row} label="Description">
              <span style="font-size: 12px; color: var(--ccem-fg-muted);">{row[:description]}</span>
            </:col>
            <:col :let={row} label="">
              <.btn variant="ghost" size="xs" phx-click="select_result" phx-value-id={row[:id]}>
                Inspect
              </.btn>
            </:col>
          </.data_table>
        </.card>
      </:main>
      <:inspector>
        <div style="padding: 16px;">
          <div :if={@selected}>
            <div style="margin-bottom: 16px;">
              <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 8px;">
                <span style="font-size: 14px; font-weight: 600; color: var(--ccem-fg);">
                  {@selected[:name]}
                </span>
                <.badge tone={result_type_tone(@selected[:type])}>{@selected[:type]}</.badge>
              </div>
              <p style="font-size: 12px; color: var(--ccem-fg-muted); margin: 0 0 12px 0;">
                {@selected[:description]}
              </p>
            </div>
            <.card padded={false} style="padding: 12px;">
              <div style="display: flex; flex-direction: column; gap: 8px; font-size: 12px;">
                <div style="display: flex; justify-content: space-between;">
                  <span style="color: var(--ccem-fg-muted);">Source</span>
                  <span style="color: var(--ccem-fg); font-family: monospace;">
                    {@selected[:source]}
                  </span>
                </div>
                <div style="display: flex; justify-content: space-between;">
                  <span style="color: var(--ccem-fg-muted);">Type</span>
                  <span style="color: var(--ccem-fg);">{@selected[:type]}</span>
                </div>
                <div style="display: flex; justify-content: space-between;">
                  <span style="color: var(--ccem-fg-muted);">Layer</span>
                  <span style="color: var(--ccem-fg);">{@active_layer}</span>
                </div>
              </div>
            </.card>
            <div style="margin-top: 12px;">
              <p style="font-size: 11px; color: var(--ccem-fg-muted); line-height: 1.5;">
                Use this solution before writing custom code. Verify security, adoption,
                compatibility, and maintenance criteria from the DRTW evaluation rubric.
              </p>
            </div>
          </div>
          <div :if={!@selected}>
            <p style="font-size: 12px; color: var(--ccem-fg-muted); text-align: center; padding: 40px 0;">
              Select a result to inspect details.
            </p>
          </div>
        </div>
      </:inspector>
    </.page_layout>
    """
  end

  # -- Private Helpers --------------------------------------------------------

  defp find_solutions(""), do: []

  defp find_solutions(_q),
    do: [
      %{
        id: "1",
        name: "NimbleOptions",
        type: "package",
        source: "hex.pm",
        description: "Declarative option validation"
      },
      %{
        id: "2",
        name: "Jason",
        type: "package",
        source: "hex.pm",
        description: "JSON encoding/decoding"
      },
      %{
        id: "3",
        name: "Finch",
        type: "package",
        source: "hex.pm",
        description: "HTTP client built on NimblePool"
      }
    ]

  defp find_by_id(results, id), do: Enum.find(results, &(&1.id == id))

  defp result_type_tone("package"), do: "success"
  defp result_type_tone("skill"), do: "iris"
  defp result_type_tone("pattern"), do: "info"
  defp result_type_tone(_), do: "neutral"
end
