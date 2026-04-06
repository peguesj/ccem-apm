defmodule ApmV5.Architectures.ArchitectureBehaviour do
  @moduledoc """
  Behaviour contract for architecture types in CCEM APM.

  An architecture defines a hierarchical composition pattern for organizing
  agents, formations, and their relationships. The first implementation is
  "Diligent" — Fleet → Formation → Squadron → Swarm → Agent.
  """

  @doc "Unique architecture name (e.g., \"diligent\")"
  @callback architecture_name() :: String.t()

  @doc "Human-readable description"
  @callback architecture_description() :: String.t()

  @doc "Version string"
  @callback architecture_version() :: String.t()

  @doc "Hierarchy levels in order from root to leaf"
  @callback levels() :: [atom()]

  @doc "Build a hierarchy tree from flat agent/formation data"
  @callback build_tree(agents :: [map()], opts :: keyword()) :: map()

  @doc "Validate that a hierarchy conforms to this architecture"
  @callback validate(tree :: map()) :: :ok | {:error, String.t()}

  @doc "Return graph rendering config (node colors, shapes, layout hints)"
  @callback graph_config() :: map()
end
