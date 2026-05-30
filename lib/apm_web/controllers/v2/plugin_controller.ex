defmodule ApmWeb.V2.PluginController do
  @moduledoc """
  REST API controller for the APM Plugin Engine.

  Routes under /api/v2/plugins:
    GET  /api/v2/plugins             — list all registered plugins
    GET  /api/v2/plugins/:name       — get plugin metadata by name
    POST /api/v2/plugins/:name/action — invoke a plugin action

  Broadcasts PubSub events on mutations to `"apm:plugins"` topic.
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmWeb.Plugs.OpenApiErrorRenderer

  alias Apm.Plugins.PluginRegistry
  alias Apm.Plugins.PluginConfigStore
  alias Apm.Plugins.ClaudeCodePluginBridge

  @pubsub Apm.PubSub
  @topic "apm:plugins"

  @doc "GET /api/v2/plugins — list all registered plugins"
  operation :index,
    summary: "List",
    tags: ["Plugins"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def index(conn, _params) do
    plugins = PluginRegistry.list_plugins()

    json(conn, %{
      data: plugins,
      count: length(plugins)
    })
  end

  @doc "GET /api/v2/plugins/:name — get a single plugin by name"
  operation :show,
    summary: "Get one",
    tags: ["Plugins"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def show(conn, %{"name" => name}) do
    case PluginRegistry.get_plugin(name) do
      {:ok, plugin} ->
        json(conn, %{data: plugin})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Plugin not found", name: name})
    end
  end

  @doc "POST /api/v2/plugins/:name/action — invoke a plugin action"
  operation :invoke_action,
    summary: "Invoke action",
    tags: ["Plugins"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def invoke_action(conn, %{"name" => name} = params) do
    action_name = params["action"] || ""
    action_params = params["params"] || %{}

    if action_name == "" do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Missing required field: action"})
    else
      case PluginRegistry.call_plugin_action(name, action_name, action_params) do
        {:ok, result} ->
          Phoenix.PubSub.broadcast(@pubsub, @topic, {:plugin_action_invoked, %{
            plugin: name,
            action: action_name,
            result: result
          }})

          json(conn, %{data: result, plugin: name, action: action_name})

        {:error, {:not_found, _}} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Plugin not found", name: name})

        {:error, {:unknown_action, action}} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Unknown action", action: action, plugin: name})

        {:error, {:missing_param, msg}} ->
          conn
          |> put_status(:bad_request)
          |> json(%{error: msg})

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{error: inspect(reason)})
      end
    end
  end

  @doc "GET /api/v2/plugins/:name/board — Kanban board state shortcut"
  operation :board,
    summary: "Board",
    tags: ["Plugins"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def board(conn, %{"name" => name} = params) do
    action_params = params |> Map.take(["project_id"]) |> drop_nils()

    case PluginRegistry.call_plugin_action(name, "board_state", action_params) do
      {:ok, result} ->
        json(conn, %{data: result, plugin: name})

      {:error, {:not_found, _}} ->
        conn |> put_status(:not_found) |> json(%{error: "Plugin not found", name: name})

      {:error, {:unknown_action, _}} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Plugin does not support board_state"})

      {:error, reason} ->
        conn |> put_status(:internal_server_error) |> json(%{error: inspect(reason)})
    end
  end

  @doc "GET /api/v2/plugins/:name/issues — list or search issues shortcut"
  operation :issues,
    summary: "Issues",
    tags: ["Plugins"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def issues(conn, %{"name" => name} = params) do
    action_params = params |> Map.take(["project_id", "query", "state_name"]) |> drop_nils()
    action_name = if Map.has_key?(action_params, "query"), do: "search_issues", else: "list_issues"

    case PluginRegistry.call_plugin_action(name, action_name, action_params) do
      {:ok, result} ->
        json(conn, %{data: result, plugin: name})

      {:error, {:not_found, _}} ->
        conn |> put_status(:not_found) |> json(%{error: "Plugin not found", name: name})

      {:error, reason} ->
        conn |> put_status(:internal_server_error) |> json(%{error: inspect(reason)})
    end
  end

  @doc "POST /api/v2/plugins/reload — re-register all default plugins"
  operation :reload,
    summary: "Reload",
    tags: ["Plugins"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def reload(conn, _params) do
    results = PluginRegistry.reload_defaults() |> Enum.map(&inspect/1)
    plugins = PluginRegistry.list_plugins()

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:plugins_reloaded, %{
      count: length(plugins)
    }})

    json(conn, %{reloaded: results, plugins: plugins, count: length(plugins)})
  end

  @doc "GET /api/v2/plugins/cc/plugins — list installed Claude Code plugins"
  operation :cc_plugins,
    summary: "Cc plugins",
    tags: ["Plugins"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def cc_plugins(conn, _params) do
    plugins = ClaudeCodePluginBridge.list_cc_plugins()
    json(conn, %{data: plugins, count: length(plugins)})
  end

  @doc "GET /api/v2/plugins/cc/summary — Claude Code plugin ecosystem summary"
  operation :cc_summary,
    summary: "Cc summary",
    tags: ["Plugins"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def cc_summary(conn, _params) do
    json(conn, %{data: ClaudeCodePluginBridge.get_summary()})
  end

  @doc "GET /api/v2/plugins/:name/config — get resolved config (defaults + overrides)"
  operation :get_config,
    summary: "Get config",
    tags: ["Plugins"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def get_config(conn, %{"name" => name}) do
    case PluginRegistry.get_plugin(name) do
      {:ok, _} ->
        config = PluginConfigStore.get_config(:plugin, name)
        schema = PluginConfigStore.get_schema(:plugin, name)
        json(conn, %{data: config, schema: schema, plugin: name})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Plugin not found", name: name})
    end
  end

  @doc "PATCH /api/v2/plugins/:name/config — update plugin config overrides"
  operation :update_config,
    summary: "Update config",
    tags: ["Plugins"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def update_config(conn, %{"name" => name} = params) do
    config = Map.get(params, "config", %{})

    case PluginRegistry.get_plugin(name) do
      {:ok, _} ->
        case PluginConfigStore.put_config(:plugin, name, config) do
          {:ok, resolved} ->
            json(conn, %{data: resolved, plugin: name})

          {:error, reasons} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Validation failed", reasons: format_errors(reasons), plugin: name})
        end

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Plugin not found", name: name})
    end
  end

  @doc "DELETE /api/v2/plugins/:name/config — reset plugin config to defaults"
  operation :reset_config,
    summary: "Reset config",
    tags: ["Plugins"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def reset_config(conn, %{"name" => name}) do
    case PluginRegistry.get_plugin(name) do
      {:ok, _} ->
        :ok = PluginConfigStore.reset_config(:plugin, name)
        defaults = PluginConfigStore.get_config(:plugin, name)
        json(conn, %{data: defaults, plugin: name, reset: true})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Plugin not found", name: name})
    end
  end

  defp format_errors(reasons) when is_list(reasons) do
    Enum.map(reasons, fn {field, msg} -> %{field: field, message: msg} end)
  end

  defp drop_nils(map), do: Enum.reject(map, fn {_k, v} -> is_nil(v) end) |> Map.new()
end
