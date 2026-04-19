defmodule ApmV5Web.V2.WidgetController do
  @moduledoc """
  REST API controller for the Dashboard Widgetization Engine (US-368).

  ## Endpoints

  - `GET /api/v2/widgets` — list all registered widget definitions
  - `GET /api/v2/widgets/:id` — get a single widget definition
  - `PATCH /api/v2/widgets/:id/config` — update session widget config override
  - `GET /api/v2/dashboard/layout` — get current layout (preset + user overrides)
  - `POST /api/v2/dashboard/layout` — save a custom layout
  - `POST /api/v2/dashboard/pin` — pin a widget as scope source
  """

  use ApmV5Web, :controller

  alias ApmV5.WidgetRegistry
  alias ApmV5.LayoutStore
  alias ApmV5.WidgetConfigStore
  alias ApmV5.DashboardScopeEngine

  # ── GET /api/v2/widgets ───────────────────────────────────────────────────────

  @doc "List all registered widget definitions."
  def index(conn, _params) do
    widgets = WidgetRegistry.list_widgets()
    json(conn, %{widgets: widgets, count: length(widgets)})
  end

  # ── GET /api/v2/widgets/:id ───────────────────────────────────────────────────

  @doc "Get a single widget definition by id."
  def show(conn, %{"id" => id}) do
    case WidgetRegistry.get_widget(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Widget not found", id: id})

      widget ->
        json(conn, widget)
    end
  end

  # ── PATCH /api/v2/widgets/:id/config ─────────────────────────────────────────

  @doc "Update widget config for a session."
  def update_config(conn, %{"id" => widget_id} = params) do
    session_id = Map.get(params, "session_id", "api")
    config = Map.get(params, "config", %{})

    case WidgetRegistry.get_widget(widget_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Widget not found", id: widget_id})

      _widget ->
        WidgetConfigStore.put_config(session_id, widget_id, config)
        merged = WidgetRegistry.resolve_config(widget_id, config)
        json(conn, %{ok: true, widget_id: widget_id, merged_config: merged})
    end
  end

  # ── GET /api/v2/dashboard/layout ─────────────────────────────────────────────

  @doc "Get the current layout for a session (user overrides merged with preset)."
  def get_layout(conn, params) do
    session_id = Map.get(params, "session_id", "api")
    preset_id = Map.get(params, "preset_id", "default")

    user_layout = LayoutStore.get_user_layout(session_id)
    preset = LayoutStore.get_preset(preset_id)

    placements =
      cond do
        user_layout && Map.get(user_layout, :placements) ->
          Map.get(user_layout, :placements)
        preset ->
          preset.placements
        true ->
          []
      end

    widget_order = user_layout && Map.get(user_layout, :widget_order)
    presets = LayoutStore.list_presets() |> Enum.map(&Map.take(&1, [:id, :name, :description]))

    json(conn, %{
      session_id: session_id,
      preset_id: preset_id,
      placements: placements,
      widget_order: widget_order,
      available_presets: presets
    })
  end

  # ── POST /api/v2/dashboard/layout ────────────────────────────────────────────

  @doc "Save a custom layout for a session."
  def save_layout(conn, %{"session_id" => session_id} = params) do
    placements = Map.get(params, "placements", [])
    preset_id = Map.get(params, "preset_id", "custom")

    layout = %{
      preset_id: preset_id,
      placements: placements,
      saved_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    LayoutStore.save_user_layout(session_id, layout)
    json(conn, %{ok: true, session_id: session_id, preset_id: preset_id})
  end

  def save_layout(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "session_id is required"})
  end

  # ── POST /api/v2/dashboard/pin ────────────────────────────────────────────────

  @doc "Pin a widget as the scope source for a session, or unpin if widget_id is nil/missing."
  def pin_widget(conn, %{"session_id" => session_id} = params) do
    widget_id = Map.get(params, "widget_id")

    if widget_id do
      case WidgetRegistry.get_widget(widget_id) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Widget not found", widget_id: widget_id})

        widget when not widget.pinnable ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Widget is not pinnable", widget_id: widget_id})

        _widget ->
          DashboardScopeEngine.pin_scope_source(session_id, widget_id)
          json(conn, %{ok: true, session_id: session_id, pinned_widget_id: widget_id})
      end
    else
      DashboardScopeEngine.unpin(session_id)
      json(conn, %{ok: true, session_id: session_id, pinned_widget_id: nil})
    end
  end

  def pin_widget(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "session_id is required"})
  end
end
