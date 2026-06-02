defmodule Apm.Integrations.RalphIntegration do
  @moduledoc "Ralph integration — bridges PRD-driven autonomous loops via IntegrationBehaviour."

  @behaviour Apm.Integrations.IntegrationBehaviour

  @impl true
  def integration_name, do: "ralph"
  @impl true
  def integration_description, do: "Ralph PRD-driven autonomous loop integration"
  @impl true
  def integration_version, do: "1.0.0"
  @impl true
  def protocol, do: :custom
  @impl true
  def required_plugin, do: "ralph"
  @impl true
  def target_native_feature, do: :workflow_engine

  @impl true
  def connect(_config), do: {:ok, %{status: :connected, connected_at: DateTime.utc_now()}}
  @impl true
  def disconnect, do: :ok
  @impl true
  def status, do: %{name: "ralph", status: :connected, version: integration_version(), protocol: :custom}

  @impl true
  def list_endpoints do
    [
      %{action: "list_prds", description: "List PRD files"},
      %{action: "trigger_loop", description: "Trigger autonomous loop"},
      %{action: "list_formations", description: "List active formations"},
      %{action: "loop_status", description: "Check loop status"}
    ]
  end

  @impl true
  def handle_event(event, data, context) do
    case event do
      action when action in ~w(list_prds get_prd trigger_loop list_formations get_formation loop_status) ->
        Apm.Plugins.Ralph.RalphPlugin.handle_action(action, data, context)
      _ ->
        {:error, "Unknown Ralph event: #{event}"}
    end
  end

  @impl true
  def supervisor_children, do: []
end
