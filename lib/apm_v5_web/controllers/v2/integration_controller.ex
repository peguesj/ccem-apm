defmodule ApmV5Web.V2.IntegrationController do
  @moduledoc """
  REST API controller for the APM Integration Engine.

  Routes under /api/v2/integrations:
    GET  /api/v2/integrations              — list all registered integrations
    GET  /api/v2/integrations/:name        — get integration metadata by name
    POST /api/v2/integrations/:name/action — invoke an integration event/action
    GET  /api/v2/integrations/:name/status — get live connectivity status
    POST /api/v2/integrations/reload       — re-register all default integrations

  Broadcasts PubSub events on mutations to `"apm:integrations"` topic.
  """

  use ApmV5Web, :controller

  alias ApmV5.Integrations.IntegrationRegistry
  alias ApmV5.Plugins.PluginConfigStore

  @pubsub ApmV5.PubSub
  @topic "apm:integrations"

  @doc "GET /api/v2/integrations — list all registered integrations"
  def index(conn, _params) do
    integrations = IntegrationRegistry.list_integrations()

    json(conn, %{
      data: integrations,
      count: length(integrations)
    })
  end

  @doc "GET /api/v2/integrations/:name — get a single integration by name"
  def show(conn, %{"name" => name}) do
    case IntegrationRegistry.get_integration(name) do
      {:ok, integration} ->
        json(conn, %{data: integration})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Integration not found", name: name})
    end
  end

  @doc "POST /api/v2/integrations/:name/action — invoke an integration event/action"
  def invoke_action(conn, %{"name" => name} = params) do
    event_type = params["action"] || params["event_type"] || ""
    payload = params["params"] || params["payload"] || %{}

    if event_type == "" do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Missing required field: action (or event_type)"})
    else
      case IntegrationRegistry.call_integration_event(name, event_type, payload) do
        {:ok, result} ->
          Phoenix.PubSub.broadcast(@pubsub, @topic, {:integration_action_invoked, %{
            integration: name,
            event: event_type,
            result: result
          }})

          json(conn, %{data: result, integration: name, event: event_type})

        {:error, {:not_found, _}} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Integration not found", name: name})

        {:error, {:unknown_action, action}} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Unknown action", action: action, integration: name})

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

  @doc "GET /api/v2/integrations/:name/status — get live connectivity status for an integration"
  def status(conn, %{"name" => name}) do
    case :ets.lookup(:integration_registry, name) do
      [{^name, {mod, meta}}] ->
        live_status =
          try do
            mod.status()
          rescue
            _ -> :disconnected
          end

        json(conn, %{
          data: %{
            name: name,
            status: live_status,
            version: meta.version,
            protocol: meta.protocol
          }
        })

      [] ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Integration not found", name: name})
    end
  end

  @doc "POST /api/v2/integrations/reload — re-register all default integrations"
  def reload(conn, _params) do
    results = IntegrationRegistry.reload_defaults() |> Enum.map(&inspect/1)
    integrations = IntegrationRegistry.list_integrations()

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:integrations_reloaded, %{
      count: length(integrations)
    }})

    json(conn, %{reloaded: results, integrations: integrations, count: length(integrations)})
  end

  @doc "GET /api/v2/integrations/:name/config — get resolved config"
  def get_config(conn, %{"name" => name}) do
    case IntegrationRegistry.get_integration(name) do
      {:ok, _} ->
        config = PluginConfigStore.get_config(:integration, name)
        schema = PluginConfigStore.get_schema(:integration, name)
        json(conn, %{data: config, schema: schema, integration: name})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Integration not found", name: name})
    end
  end

  @doc "PATCH /api/v2/integrations/:name/config — update integration config"
  def update_config(conn, %{"name" => name} = params) do
    config = Map.get(params, "config", %{})

    case IntegrationRegistry.get_integration(name) do
      {:ok, _} ->
        case PluginConfigStore.put_config(:integration, name, config) do
          {:ok, resolved} ->
            json(conn, %{data: resolved, integration: name})

          {:error, reasons} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Validation failed", reasons: format_errors(reasons), integration: name})
        end

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Integration not found", name: name})
    end
  end

  @doc "DELETE /api/v2/integrations/:name/config — reset integration config to defaults"
  def reset_config(conn, %{"name" => name}) do
    case IntegrationRegistry.get_integration(name) do
      {:ok, _} ->
        :ok = PluginConfigStore.reset_config(:integration, name)
        defaults = PluginConfigStore.get_config(:integration, name)
        json(conn, %{data: defaults, integration: name, reset: true})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Integration not found", name: name})
    end
  end

  defp format_errors(reasons) when is_list(reasons) do
    Enum.map(reasons, fn {field, msg} -> %{field: field, message: msg} end)
  end
end
