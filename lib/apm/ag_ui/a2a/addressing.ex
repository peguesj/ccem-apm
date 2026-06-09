defmodule Apm.AgUi.A2A.Addressing do
  @moduledoc """
  Resolves A2A addresses to target agent IDs.

  ## US-030 DoD: resolve/1 returns target agent_ids for each address type.
  """

  @doc "Resolves an address to a list of target agent IDs."
  @spec resolve(Apm.AgUi.A2A.Envelope.address()) :: [String.t()]
  def resolve({:agent, agent_id}), do: [agent_id]

  def resolve({:formation, formation_id}) do
    try do
      case Apm.UpmStore.get_formation(formation_id) do
        nil ->
          []

        formation ->
          Map.get(formation, :agents, [])
          |> Enum.map(&(&1[:agent_id] || &1["agent_id"]))
          |> Enum.reject(&is_nil/1)
      end
    rescue
      _ -> []
    end
  end

  def resolve({:squadron, squadron_id}) do
    try do
      Apm.AgentRegistry.list_agents()
      |> Enum.filter(fn agent ->
        (agent[:formation_role] == "squadron_lead" and agent[:agent_id] == squadron_id) or
          agent[:parent_agent_id] == squadron_id
      end)
      |> Enum.map(& &1[:agent_id])
    rescue
      _ -> []
    end
  end

  def resolve({:topic, topic}) when is_binary(topic) do
    # Topic-based addressing: only agents explicitly subscribed via TopicRegistry.
    # Previously returned ALL agents (silent broadcast amplification — coord-a2 fix).
    try do
      Apm.AgUi.A2A.TopicRegistry.get_subscribers(topic)
    rescue
      _ -> []
    end
  end

  def resolve(:broadcast) do
    try do
      Apm.AgentRegistry.list_agents()
      |> Enum.map(& &1[:agent_id])
    rescue
      _ -> []
    end
  end

  def resolve(_), do: []
end
