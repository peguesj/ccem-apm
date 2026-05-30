defmodule Apm.Integrations.Lvm.LvmIntegration do
  @moduledoc """
  Integration bridge between APM and Claude Platform LVM capabilities.

  Connects APM's usage tracking system to model capability metadata,
  enabling real-time model status monitoring and usage limit awareness.

  ## Integration Type
  This is an `lvm_manager` type integration -- it manages the mapping
  between model identifiers and their capability constraints.
  """

  @behaviour Apm.Integrations.IntegrationBehaviour

  alias Apm.ClaudeUsageStore
  alias Apm.Plugins.Lvm.ClaudePlatformLvmPlugin

  @impl true
  def integration_name, do: "lvm_manager"

  @impl true
  def integration_description,
    do: "Claude Platform LVM capability tracking and usage limit monitoring"

  @impl true
  def integration_version, do: "1.0.0"

  @impl true
  def protocol, do: :internal

  @impl true
  def connect(_config), do: {:ok, %{connected_at: DateTime.utc_now() |> DateTime.to_iso8601()}}

  @impl true
  def disconnect, do: :ok

  @impl true
  def status, do: :connected

  @impl true
  def list_endpoints do
    [
      %{action: "get_model_limits", description: "Get model capability limits", params: %{model: "string"}},
      %{action: "get_usage_status", description: "Get usage status for all models", params: %{}},
      %{action: "record_capability", description: "Record dynamic model capability", params: %{model: "string", capabilities: "map"}}
    ]
  end

  @impl true
  def handle_event("get_model_limits", %{"model" => model}, _opts) do
    case ClaudePlatformLvmPlugin.get_capabilities(model) do
      nil ->
        case ClaudeUsageStore.get_model_capabilities(model) do
          nil -> {:error, {:unknown_model, model}}
          caps -> {:ok, %{model: model, capabilities: caps, source: "dynamic"}}
        end

      caps ->
        {:ok, %{model: model, capabilities: caps, source: "static"}}
    end
  end

  def handle_event("get_usage_status", _payload, _opts) do
    summary = ClaudeUsageStore.get_summary()
    models = ClaudePlatformLvmPlugin.known_models()

    {:ok, %{
      summary: summary,
      known_models: Map.keys(models),
      model_count: map_size(models)
    }}
  end

  def handle_event("record_capability", %{"model" => model, "capabilities" => caps}, _opts)
      when is_map(caps) do
    :ok = ClaudeUsageStore.record_model_capabilities(model, caps)
    {:ok, %{model: model, recorded: true}}
  end

  def handle_event(event, _payload, _opts) do
    {:error, {:unknown_event, event}}
  end

  @impl true
  def supervisor_children, do: []

  # -- Optional callbacks for symbiosis ----------------------------------------

  @impl true
  def required_plugin, do: "claude_platform_lvm"

  @impl true
  def target_native_feature, do: :usage_tracking
end
