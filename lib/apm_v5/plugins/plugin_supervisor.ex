defmodule ApmV5.Plugins.PluginSupervisor do
  @moduledoc "DynamicSupervisor that manages supervised processes owned by plugins."

  use DynamicSupervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg),
    do: DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)

  @impl true
  def init(_init_arg), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Start all child specs returned by a plugin's supervisor_children/0."
  @spec start_plugin_children([Supervisor.child_spec()]) :: [DynamicSupervisor.on_start_child()]
  def start_plugin_children(children) when is_list(children) do
    Enum.map(children, &DynamicSupervisor.start_child(__MODULE__, &1))
  end
end
