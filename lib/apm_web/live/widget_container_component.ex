defmodule ApmWeb.Live.WidgetContainerComponent do
  @moduledoc """
  LiveComponent: wrapper for any dashboard widget with title bar and control affordances.

  Renders a card with:
  - Title bar: widget name (or custom title), edit button (pencil), pin button (pushpin)
  - Pin badge shown when `is_pinned=true`
  - Edit panel slot: renders WidgetEditPanelComponent inline
  - Body slot: the actual widget content
  - Resize handle: delegates to existing WidgetResize JS hook

  The resizable body wrapper uses `phx-update="ignore"` so the WidgetResize JS hook
  can manage DOM height without LiveView overwriting it.

  ## Attrs

  - `widget` - WidgetRegistry widget definition map (required)
  - `current_config` - map of config overrides for this session (default: %{})
  - `is_pinned` - boolean, shows pin badge when true (default: false)
  - `is_edit_open` - boolean, shows edit panel when true (default: false)
  - `scope_type` - atom, current active scope type (default: :global)
  - `scope_value` - string or nil, current scope value (default: nil)

  ## Usage

      <.live_component
        module={ApmWeb.Live.WidgetContainerComponent}
        id="widget-container-WIDGET_ID"
        widget={widget}
        current_config={current_config}
        is_pinned={widget_pinned_id == widget.id}
        is_edit_open={widget_edit_panel_id == widget.id}
        scope_type={widget_scope_type}
        scope_value={widget_scope_value}
      >
        <:body>
          <!-- Widget content here -->
        </:body>
      </.live_component>
  """

  use ApmWeb, :live_component

  alias ApmWeb.Live.WidgetEditPanelComponent

  @impl true
  def update(assigns, socket) do
    widget = assigns.widget
    current_config = assigns[:current_config] || %{}
    merged_config = Map.merge(widget.default_config || %{}, current_config)
    custom_title = Map.get(merged_config, :custom_title) || Map.get(merged_config, "custom_title")

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:current_config, current_config)
     |> assign(:merged_config, merged_config)
     |> assign(:is_pinned, assigns[:is_pinned] || false)
     |> assign(:is_edit_open, assigns[:is_edit_open] || false)
     |> assign(:scope_type, assigns[:scope_type] || :global)
     |> assign(:scope_value, assigns[:scope_value])
     |> assign(:display_title, custom_title || widget.name)}
  end

  slot :body, required: true

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={"widget-container-#{@widget.id}"}
      class="relative bg-base-200 border border-base-300 rounded-lg overflow-visible"
      data-widget-id={@widget.id}
      phx-hook="WidgetResize"
    >
      <%!-- Title bar --%>
      <div class="flex items-center justify-between px-3 py-1.5 border-b border-base-300 bg-base-300/40 rounded-t-lg">
        <div class="flex items-center gap-1.5 min-w-0">
          <%!-- Pin badge --%>
          <%= if @is_pinned do %>
            <span class="badge badge-primary badge-xs gap-0.5" title="Scope source pinned">
              <svg class="w-2.5 h-2.5" fill="currentColor" viewBox="0 0 24 24">
                <path d="M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7z" />
              </svg>
              pinned
            </span>
          <% end %>
          <span class="text-xs font-medium text-base-content truncate" title={@display_title}>
            {@display_title}
          </span>
        </div>

        <div class="flex items-center gap-0.5 flex-shrink-0">
          <%!-- Edit button (only if editable) --%>
          <%= if @widget.editable do %>
            <button
              phx-click="widget_edit_open"
              phx-value-widget_id={@widget.id}
              class={[
                "btn btn-ghost btn-xs px-1.5 h-6 min-h-0",
                if(@is_edit_open,
                  do: "text-primary",
                  else: "text-base-content/50 hover:text-base-content"
                )
              ]}
              aria-label={"Edit #{@widget.name} settings"}
              title="Edit widget settings"
            >
              <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
                />
              </svg>
            </button>
          <% end %>

          <%!-- Pin button (only if pinnable) --%>
          <%= if @widget.pinnable do %>
            <button
              phx-click="widget_pin_toggle"
              phx-value-widget_id={@widget.id}
              class={[
                "btn btn-ghost btn-xs px-1.5 h-6 min-h-0",
                if(@is_pinned,
                  do: "text-primary",
                  else: "text-base-content/50 hover:text-base-content"
                )
              ]}
              aria-label={if @is_pinned, do: "Unpin scope source", else: "Pin as scope source"}
              title={
                if @is_pinned,
                  do: "Unpin — restore global scope",
                  else: "Pin to drive scope for all widgets"
              }
            >
              <svg
                class="w-3.5 h-3.5"
                fill={if(@is_pinned, do: "currentColor", else: "none")}
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M5 5a2 2 0 012-2h10a2 2 0 012 2v16l-7-3.5L5 21V5z"
                />
              </svg>
            </button>
          <% end %>
        </div>
      </div>

      <%!-- Edit panel (absolutely positioned, z-layered) --%>
      <%= if @is_edit_open && @widget.editable do %>
        <.live_component
          module={WidgetEditPanelComponent}
          id={"edit-panel-#{@widget.id}"}
          widget={@widget}
          current_config={@current_config}
          is_open={true}
        />
      <% end %>

      <%!-- Widget body — phx-update=ignore so WidgetResize JS hook controls height --%>
      <div
        data-resizable
        phx-update="ignore"
        id={"widget-body-#{@widget.id}"}
        class="overflow-auto"
      >
        {render_slot(@body)}
      </div>
    </div>
    """
  end
end
