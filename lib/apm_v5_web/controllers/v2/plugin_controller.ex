defmodule ApmV5Web.V2.PluginController do
  @moduledoc """
  REST API controller for the APM Plugin Engine.

  Routes under /api/v2/plugins:
    GET  /api/v2/plugins             — list all registered plugins
    GET  /api/v2/plugins/:name       — get plugin metadata by name
    POST /api/v2/plugins/:name/action — invoke a plugin action
  """

  use ApmV5Web, :controller

  alias ApmV5.Plugins.PluginRegistry

  @doc "GET /api/v2/plugins — list all registered plugins"
  def index(conn, _params) do
    plugins = PluginRegistry.list_plugins()

    json(conn, %{
      data: plugins,
      count: length(plugins)
    })
  end

  @doc "GET /api/v2/plugins/:name — get a single plugin by name"
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
  def reload(conn, _params) do
    results = PluginRegistry.reload_defaults() |> Enum.map(&inspect/1)
    plugins = PluginRegistry.list_plugins()
    json(conn, %{reloaded: results, plugins: plugins, count: length(plugins)})
  end

  defp drop_nils(map), do: Enum.reject(map, fn {_k, v} -> is_nil(v) end) |> Map.new()
end
