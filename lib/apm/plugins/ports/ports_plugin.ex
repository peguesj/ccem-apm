defmodule Apm.Plugins.Ports.PortsPlugin do
  @moduledoc """
  APM Plugin wrapping the PortManager.

  Exposes the following actions:
    - "get_port_map"       — return the full port map
    - "scan_active_ports"  — scan OS for active ports
    - "detect_clashes"     — detect port clashes
    - "get_project_configs" — return project port configs
    - "assign_port"        — assign a port to a namespace
    - "suggest_remediation" — suggest remediation for a port conflict
    - "get_port_ranges"    — return namespace port ranges
  """

  @behaviour Apm.Plugins.PluginBehaviour

  alias Apm.PortManager

  # ── PluginBehaviour ──────────────────────────────────────────────────────────

  @impl true
  @spec plugin_name() :: String.t()
  def plugin_name, do: "ports"

  @impl true
  @spec plugin_description() :: String.t()
  def plugin_description,
    do: "Port manager — track, assign, clash-detect, and remediate developer ports"

  @impl true
  @spec plugin_version() :: String.t()
  def plugin_version, do: "1.0.0"

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{
        action: "get_port_map",
        description: "Return the full port allocation map",
        params: %{}
      },
      %{
        action: "scan_active_ports",
        description: "Scan the OS for actively listening ports",
        params: %{}
      },
      %{
        action: "detect_clashes",
        description: "Detect port clashes across registered namespaces",
        params: %{}
      },
      %{
        action: "get_project_configs",
        description: "Return per-project port configurations",
        params: %{}
      },
      %{
        action: "assign_port",
        description: "Assign a port to a namespace (web | api | service | tool) or project name",
        params: %{namespace: "string"}
      },
      %{
        action: "suggest_remediation",
        description: "Suggest remediation for a conflicting port number",
        params: %{port: "integer"}
      },
      %{
        action: "get_port_ranges",
        description: "Return the namespace-to-port-range map",
        params: %{}
      }
    ]
  end

  @impl true
  @spec handle_action(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_action("get_port_map", _params, _opts) do
    port_map = PortManager.get_port_map()
    {:ok, %{port_map: port_map}}
  end

  def handle_action("scan_active_ports", _params, _opts) do
    result = PortManager.scan_active_ports()
    {:ok, %{active_ports: result}}
  end

  def handle_action("detect_clashes", _params, _opts) do
    clashes = PortManager.detect_clashes()
    {:ok, %{clashes: clashes, count: length(clashes)}}
  end

  def handle_action("get_project_configs", _params, _opts) do
    configs = PortManager.get_project_configs()
    {:ok, %{project_configs: configs}}
  end

  def handle_action("assign_port", %{"namespace" => namespace}, _opts) do
    ns = if namespace in ["web", "api", "service", "tool"],
      do: String.to_existing_atom(namespace),
      else: namespace

    case PortManager.assign_port(ns) do
      {:ok, port} -> {:ok, %{port: port, namespace: namespace}}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_action("assign_port", _params, _opts) do
    {:error, {:missing_param, "namespace is required"}}
  end

  def handle_action("suggest_remediation", %{"port" => port}, _opts) do
    port_int = if is_binary(port), do: String.to_integer(port), else: port
    remediation = PortManager.suggest_remediation(port_int)
    {:ok, %{remediation: remediation}}
  end

  def handle_action("suggest_remediation", _params, _opts) do
    {:error, {:missing_param, "port is required"}}
  end

  def handle_action("get_port_ranges", _params, _opts) do
    ranges = PortManager.get_port_ranges()
    {:ok, %{port_ranges: ranges}}
  end

  def handle_action(action, _params, _opts) do
    {:error, {:unknown_action, action}}
  end

  @impl true
  @spec supervisor_children() :: [Supervisor.child_spec()]
  def supervisor_children, do: []

  @impl true
  @spec default_enabled?() :: boolean()
  def default_enabled?, do: true
end
