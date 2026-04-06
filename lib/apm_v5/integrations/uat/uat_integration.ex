defmodule ApmV5.Integrations.Uat.UatIntegration do
  @moduledoc "UAT integration — delegates test operations to UatPlugin"

  @behaviour ApmV5.Integrations.IntegrationBehaviour

  @impl true
  def integration_name, do: "uat"
  @impl true
  def integration_description, do: "UAT — user acceptance testing via plugin bridge"
  @impl true
  def integration_version, do: "1.0.0"
  @impl true
  def protocol, do: :custom
  @impl true
  def required_plugin, do: "uat"
  @impl true
  def target_native_feature, do: :test_runner

  @impl true
  def connect(_config), do: {:ok, %{}}
  @impl true
  def disconnect, do: :ok
  @impl true
  def status do
    case ApmV5.Plugins.PluginRegistry.get_plugin("uat") do
      {:ok, _} -> :connected
      _ -> :disconnected
    end
  rescue
    _ -> :disconnected
  end

  @impl true
  def list_endpoints do
    [
      %{action: "list_test_suites", description: "List available test suites"},
      %{action: "run_test", description: "Run a specific test suite"},
      %{action: "get_results", description: "Get test results"}
    ]
  end

  @impl true
  def handle_event("list_test_suites", _payload, _opts) do
    {:ok, %{suites: [], count: 0}}
  end

  def handle_event("run_test", %{"suite" => suite}, _opts) do
    {:ok, %{status: "queued", suite: suite, timestamp: DateTime.utc_now()}}
  end

  def handle_event("get_results", _payload, _opts) do
    {:ok, %{results: [], count: 0}}
  end

  def handle_event(event, _payload, _opts), do: {:error, {:unknown_event, event}}

  @impl true
  def supervisor_children, do: []
end
