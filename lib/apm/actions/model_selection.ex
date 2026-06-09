defmodule Apm.Actions.ModelSelection do
  @moduledoc "Assess optimal Claude model per skill based on complexity and cost."

  @models %{
    "opus" => %{capability: 100, cost_per_1k: 15.0, id: "claude-opus-4-6"},
    "sonnet" => %{capability: 85, cost_per_1k: 3.0, id: "claude-sonnet-4-6"},
    "haiku" => %{capability: 65, cost_per_1k: 0.25, id: "claude-haiku-4-5-20251001"}
  }

  @skill_complexity %{
    "orchestrator" => 95,
    "coalesce" => 90,
    "formation" => 85,
    "refactor-max" => 85,
    "ralph" => 80,
    "double-verify" => 80,
    "upm" => 75,
    "ship" => 70,
    "fix" => 60,
    "tests" => 55,
    "build" => 50,
    "grep" => 20,
    "glob" => 15,
    "read" => 10
  }

  @skill_deps %{
    "orchestrator" => ["formation", "ralph"],
    "coalesce" => ["ralph"],
    "formation" => ["upm"],
    "ralph" => ["fix", "build", "tests"],
    "upm" => ["ship"],
    "ship" => ["build", "tests"],
    "fix" => ["read", "grep"],
    "tests" => ["read"],
    "build" => ["read"]
  }

  @role_complexity %{
    "orchestrator" => 95,
    "squadron_lead" => 80,
    "swarm_agent" => 65,
    "cluster_agent" => 55,
    "individual" => 40,
    "persistent_service" => 50
  }

  @default 50

  @spec recommend(String.t()) :: {:ok, map()}
  def recommend(skill) do
    c = complexity_score(skill)
    {tier, m} = select(c)

    {:ok,
     %{skill: skill, complexity: c, model_id: m.id, model_tier: tier, cost_per_1k: m.cost_per_1k}}
  end

  @spec recommend_for_formation(String.t()) :: {:ok, map()}
  def recommend_for_formation(role) do
    c = Map.get(@role_complexity, role, @default)
    {tier, m} = select(c)

    {:ok,
     %{role: role, complexity: c, model_id: m.id, model_tier: tier, cost_per_1k: m.cost_per_1k}}
  end

  @spec list_models() :: map()
  def list_models, do: @models

  @spec complexity_score(String.t()) :: non_neg_integer()
  def complexity_score(skill), do: Map.get(@skill_complexity, skill, @default)

  @spec resolve_chain(String.t()) :: [String.t()]
  def resolve_chain(skill), do: do_chain([skill], MapSet.new(), []) |> Enum.reverse()

  @spec cost_optimize(String.t(), non_neg_integer()) :: {:ok, map()}
  def cost_optimize(skill, min_cap) do
    {tier, m} =
      @models
      |> Enum.sort_by(fn {_, m} -> m.cost_per_1k end)
      |> Enum.find(fn {_, m} -> m.capability >= min_cap end) || {"opus", @models["opus"]}

    {:ok,
     %{
       skill: skill,
       min_capability: min_cap,
       model_id: m.id,
       model_tier: tier,
       cost_per_1k: m.cost_per_1k
     }}
  end

  defp select(c) when c >= 90, do: {"opus", @models["opus"]}
  defp select(c) when c >= 50, do: {"sonnet", @models["sonnet"]}
  defp select(_), do: {"haiku", @models["haiku"]}

  defp do_chain([], _v, acc), do: acc

  defp do_chain([h | t], v, acc) do
    if MapSet.member?(v, h),
      do: do_chain(t, v, acc),
      else: do_chain(t ++ Map.get(@skill_deps, h, []), MapSet.put(v, h), [h | acc])
  end
end
