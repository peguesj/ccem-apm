defmodule Apm.Integrations.ClaudeMem.ClaudeMemIntegration do
  @moduledoc """
  Claude Memory integration — delegates to `Apm.Plugins.Memory.MemoryPlugin`.

  This module satisfies `Apm.Integrations.IntegrationBehaviour` and keeps its
  original public surface intact for backward compatibility.  All substantive
  logic is now handled by the MemoryPlugin; the three legacy events are mapped
  to their plugin counterparts:

  | Legacy event       | Plugin action        |
  |--------------------|----------------------|
  | `list_memories`    | `list_observations`  |
  | `search_memories`  | `search_observations`|
  | `get_memory`       | `get_observation`    |

  > #### Deprecated {: .warning}
  > Callers should migrate to `Apm.Plugins.Memory.MemoryPlugin.handle_action/3`
  > directly.  This integration shim will be removed in a future major version.
  """

  @behaviour Apm.Integrations.IntegrationBehaviour

  alias Apm.Plugins.Memory.MemoryPlugin

  @impl true
  def integration_name, do: "claude_mem"
  @impl true
  def integration_description,
    do: "Claude Memory — project memory file access and search (delegates to MemoryPlugin)"

  @impl true
  def integration_version, do: "2.0.0"
  @impl true
  def protocol, do: :rest
  @impl true
  def required_plugin, do: :memory
  @impl true
  def target_native_feature, do: :memory_system

  @impl true
  def connect(_config), do: {:ok, %{delegated_to: MemoryPlugin}}
  @impl true
  def disconnect, do: :ok
  @impl true
  def status, do: :connected

  @impl true
  def list_endpoints do
    [
      %{
        action: "list_memories",
        description:
          "List observations — delegates to MemoryPlugin list_observations (deprecated)"
      },
      %{
        action: "search_memories",
        description:
          "Search observations — delegates to MemoryPlugin search_observations (deprecated)"
      },
      %{
        action: "get_memory",
        description:
          "Get observation by id — delegates to MemoryPlugin get_observation (deprecated)"
      }
    ]
  end

  @doc deprecated:
         "Use Apm.Plugins.Memory.MemoryPlugin.handle_action/3 with action \"list_observations\" instead."
  @impl true
  def handle_event("list_memories", params, opts) do
    MemoryPlugin.handle_action("list_observations", params, opts)
  end

  @doc deprecated:
         "Use Apm.Plugins.Memory.MemoryPlugin.handle_action/3 with action \"search_observations\" instead."
  def handle_event("search_memories", %{"query" => query} = _payload, opts) do
    MemoryPlugin.handle_action("search_observations", %{"query" => query}, opts)
  end

  @doc deprecated:
         "Use Apm.Plugins.Memory.MemoryPlugin.handle_action/3 with action \"get_observation\" instead."
  def handle_event("get_memory", %{"path" => id} = _payload, opts) do
    MemoryPlugin.handle_action("get_observation", %{"id" => id}, opts)
  end

  def handle_event(event, _payload, _opts), do: {:error, {:unknown_event, event}}

  @impl true
  def supervisor_children, do: []
end
