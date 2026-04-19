defmodule ApmV5Web.Live.WidgetEditPanelComponent do
  @moduledoc """
  LiveComponent: inline config editor panel for a single widget.

  Renders an absolute-positioned edit panel that slides in from the top-right of
  a widget. Dynamically generates form fields from the widget's config_schema:

  - "boolean" -> daisyUI toggle checkbox
  - "string"  -> text input
  - "integer" -> number input
  - "enum:a,b,c" -> select with options

  On save, sends `widget_config_saved` to the parent LiveView with the merged config.
  On close, sends `widget_edit_close`.

  The outer wrapper uses `phx-update="ignore"` to allow JS animation without
  LiveView overwriting DOM state.

  ## Usage

      <.live_component
        module={ApmV5Web.Live.WidgetEditPanelComponent}
        id="edit-panel-WIDGET_ID"
        widget={widget}
        current_config={current_config}
        is_open={widget_edit_panel_id == widget.id}
      />
  """

  use ApmV5Web, :live_component

  @impl true
  def update(assigns, socket) do
    widget = assigns.widget
    current_config = assigns[:current_config] || %{}
    merged_config = Map.merge(widget.default_config || %{}, current_config)

    {:ok,
     socket
     |> assign(:widget, widget)
     |> assign(:current_config, merged_config)
     |> assign(:is_open, assigns[:is_open] || false)
     |> assign(:form_data, stringify_config(merged_config))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={"widget-edit-panel-#{@widget.id}"}
      class={[
        "absolute right-0 top-8 z-50 w-72 bg-base-200 border border-base-300 rounded-lg shadow-xl",
        "transition-all duration-200",
        if(@is_open, do: "opacity-100 pointer-events-auto", else: "opacity-0 pointer-events-none")
      ]}
    >
      <div class="p-3">
        <%!-- Header --%>
        <div class="flex items-center justify-between mb-3">
          <h3 class="text-sm font-semibold text-base-content">Edit Widget</h3>
          <button
            phx-click="widget_edit_close"
            phx-target={@myself}
            class="btn btn-ghost btn-xs"
            aria-label="Close edit panel"
          >
            <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
            </svg>
          </button>
        </div>

        <%!-- Static fields: title override --%>
        <div class="form-control mb-2">
          <label class="label py-0.5">
            <span class="label-text text-xs">Custom Title</span>
          </label>
          <input
            type="text"
            name="custom_title"
            value={Map.get(@form_data, "custom_title", "")}
            placeholder={@widget.name}
            class="input input-bordered input-xs w-full"
            phx-blur="form_field_change"
            phx-value-field="custom_title"
            phx-target={@myself}
          />
        </div>

        <%!-- Dynamic config_schema fields --%>
        <%= for {key, schema_type} <- @widget.config_schema do %>
          <div class="form-control mb-2">
            <%= render_field(assigns, key, schema_type) %>
          </div>
        <% end %>

        <%!-- Actions --%>
        <div class="flex gap-2 mt-3 pt-2 border-t border-base-300">
          <button
            phx-click="save_config"
            phx-target={@myself}
            class="btn btn-primary btn-xs flex-1"
          >
            Save
          </button>
          <button
            phx-click="widget_edit_close"
            phx-target={@myself}
            class="btn btn-ghost btn-xs flex-1"
          >
            Cancel
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ── Event Handlers ────────────────────────────────────────────────────────────

  @impl true
  def handle_event("widget_edit_close", _params, socket) do
    send(self(), {:widget_edit_close, socket.assigns.widget.id})
    send_update_parent(socket, "widget_edit_close", %{})
    {:noreply, assign(socket, :is_open, false)}
  end

  @impl true
  def handle_event("form_field_change", %{"field" => field, "value" => value}, socket) do
    updated = Map.put(socket.assigns.form_data, field, value)
    {:noreply, assign(socket, :form_data, updated)}
  end

  @impl true
  def handle_event("toggle_field", %{"field" => field}, socket) do
    current = Map.get(socket.assigns.form_data, field, "false")
    toggled = if current in ["true", true], do: "false", else: "true"
    updated = Map.put(socket.assigns.form_data, field, toggled)
    {:noreply, assign(socket, :form_data, updated)}
  end

  @impl true
  def handle_event("save_config", _params, socket) do
    widget_id = socket.assigns.widget.id
    config = parse_config(socket.assigns.form_data, socket.assigns.widget.config_schema)

    send(self(), {:widget_config_saved_internal, widget_id, config})

    # Also notify parent LiveView via phx-target parent event
    send_parent_event(socket, "widget_config_saved", %{
      "widget_id" => widget_id,
      "config" => config
    })

    {:noreply, assign(socket, :is_open, false)}
  end

  # ── Private Helpers ───────────────────────────────────────────────────────────

  defp render_field(assigns, key, "boolean") do
    key_str = to_string(key)
    label = humanize_key(key_str)
    checked = Map.get(assigns.form_data, key_str, "false") in ["true", true]

    assigns = assign(assigns, key_str: key_str, label: label, checked: checked)

    ~H"""
    <label class="label cursor-pointer py-0.5">
      <span class="label-text text-xs"><%= @label %></span>
      <input
        type="checkbox"
        class="toggle toggle-primary toggle-xs"
        checked={@checked}
        phx-click="toggle_field"
        phx-value-field={@key_str}
        phx-target={@myself}
      />
    </label>
    """
  end

  defp render_field(assigns, key, "integer") do
    key_str = to_string(key)
    label = humanize_key(key_str)
    value = Map.get(assigns.form_data, key_str, "")

    assigns = assign(assigns, key_str: key_str, label: label, field_value: value)

    ~H"""
    <div>
      <label class="label py-0.5">
        <span class="label-text text-xs"><%= @label %></span>
      </label>
      <input
        type="number"
        class="input input-bordered input-xs w-full"
        value={@field_value}
        phx-blur="form_field_change"
        phx-value-field={@key_str}
        phx-target={@myself}
      />
    </div>
    """
  end

  defp render_field(assigns, key, "enum:" <> options_str) do
    key_str = to_string(key)
    label = humanize_key(key_str)
    options = String.split(options_str, ",")
    current = Map.get(assigns.form_data, key_str, List.first(options) || "")

    assigns = assign(assigns, key_str: key_str, label: label, options: options, current: current)

    ~H"""
    <div>
      <label class="label py-0.5">
        <span class="label-text text-xs"><%= @label %></span>
      </label>
      <select
        class="select select-bordered select-xs w-full"
        phx-change="form_field_change"
        phx-value-field={@key_str}
        phx-target={@myself}
      >
        <%= for opt <- @options do %>
          <option value={opt} selected={opt == @current}><%= opt %></option>
        <% end %>
      </select>
    </div>
    """
  end

  defp render_field(assigns, key, _schema_type) do
    # Default: text input
    key_str = to_string(key)
    label = humanize_key(key_str)
    value = Map.get(assigns.form_data, key_str, "")

    assigns = assign(assigns, key_str: key_str, label: label, field_value: value)

    ~H"""
    <div>
      <label class="label py-0.5">
        <span class="label-text text-xs"><%= @label %></span>
      </label>
      <input
        type="text"
        class="input input-bordered input-xs w-full"
        value={@field_value}
        phx-blur="form_field_change"
        phx-value-field={@key_str}
        phx-target={@myself}
      />
    </div>
    """
  end

  defp stringify_config(config) do
    Map.new(config, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp parse_config(form_data, config_schema) do
    Map.new(config_schema, fn {key, schema_type} ->
      key_str = to_string(key)
      raw = Map.get(form_data, key_str, "")

      value =
        case schema_type do
          "boolean" -> raw in ["true", true]
          "integer" -> String.to_integer(raw)
          _ -> raw
        end

      {key, value}
    end)
  rescue
    _ -> Map.new(form_data, fn {k, v} -> {String.to_atom(k), v} end)
  end

  defp humanize_key(key_str) do
    key_str
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp send_parent_event(socket, event, params) do
    # Send to parent LiveView process
    send(self(), {event, params})
    socket
  end

  defp send_update_parent(socket, event, params) do
    send(self(), {event, params})
    socket
  end
end
