defmodule Apm.AgentRegistry.Horde do
  @moduledoc """
  Distributed Horde registry for multi-node agent process lookup (coord-v10.0-d2 / CP-289).

  This is a **sibling** to `Apm.AgentRegistry` (ETS-backed, single-node) — it does
  NOT replace it.  Both run concurrently under the supervision tree.  The active
  backend for the public API is selected by:

      config :apm, :agent_registry_backend, :ets   # default (unchanged)
      config :apm, :agent_registry_backend, :horde # multi-node mode

  ## Design rationale

  The full ETS → Horde migration is a separate breaking story for the v10.0.0 ship.
  This story (coord-v10.0-d2) only stages the infrastructure:
  1. Both registry types compile and start without error.
  2. `Apm.AgentRegistry.Horde` is a live `Horde.Registry` that accepts registrations.
  3. `Apm.AgentRegistry` ETS behavior is completely unchanged.

  ## Horde.Registry child name

  `Apm.AgentRegistry.Horde` — referenced by this exact name in the supervisor tree.

  ## Single-node vs. multi-node

  On a single node, Horde.Registry behaves identically to a local Registry with
  CRDT bookkeeping overhead.  Multi-node convergence happens automatically when
  libcluster connects nodes and `Horde.Cluster.set_members/2` is called.

  ## API

  Use standard `Horde.Registry` calls:

      # Register current process under agent_id
      Horde.Registry.register(Apm.AgentRegistry.Horde, agent_id, metadata)

      # Look up a registered agent process
      Horde.Registry.lookup(Apm.AgentRegistry.Horde, agent_id)

  """

  use Horde.Registry

  @doc "Start the distributed registry under the supervisor."
  def start_link(opts \\ []) do
    Horde.Registry.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    [keys: :unique, members: members()]
    |> Keyword.merge(opts)
    |> Horde.Registry.init()
  end

  # Build members list: current node plus any connected nodes.
  # On a single node this is just [{__MODULE__, Node.self()}].
  defp members do
    [Node.self() | Node.list()]
    |> Enum.map(fn node -> {__MODULE__, node} end)
  end
end
