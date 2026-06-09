defmodule Apm.Auth.FormationRateLimiterTest do
  @moduledoc """
  TDD suite for FormationRateLimiter extensions:

  - rl-s9 (CP-264): top_n_agents/2 query helper — top-N agents by current
    Hammer bucket usage within a formation.
  - rl-s10 (CP-265): heatmap_data/1 — utilization percentage per tool for
    a formation.
  """

  use ExUnit.Case, async: false

  alias Apm.Auth.FormationRateLimiter

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_formation, do: "frl-test-#{System.unique_integer([:positive, :monotonic])}"

  defp unique_agent(prefix \\ "agent"),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  # Pump `n` hits for `agent_id:tool_name` directly via Hammer so we control
  # exact bucket usage without triggering formation-level checks.
  defp pump_agent_hits(agent_id, tool_name, n) do
    key = "#{agent_id}:#{tool_name}"

    for _ <- 1..n do
      Apm.RateLimit.hit(key, :timer.seconds(60), 10_000)
    end
  end

  # Pump n formation-level hits for heatmap tests.
  defp pump_formation_hits(formation_id, tool_name, n) do
    key = "formation:#{formation_id}:#{tool_name}"

    for _ <- 1..n do
      Apm.RateLimit.hit(key, :timer.seconds(60), 10_000)
    end
  end

  # ---------------------------------------------------------------------------
  # rl-s9 — top_n_agents/2
  # ---------------------------------------------------------------------------

  describe "top_n_agents/2 — CP-264 / rl-s9" do
    test "returns empty list when no agents have bucket usage" do
      formation_id = unique_formation()
      result = FormationRateLimiter.top_n_agents(formation_id, 10)
      assert result == []
    end

    test "returns agents sorted descending by bucket usage" do
      formation_id = unique_formation()
      tool = "Bash"

      a1 = unique_agent("top-a1")
      a2 = unique_agent("top-a2")
      a3 = unique_agent("top-a3")

      # Register agents in the formation so they are discoverable
      pump_agent_hits(a1, tool, 3)
      pump_agent_hits(a2, tool, 7)
      pump_agent_hits(a3, tool, 5)

      # Provide the formation_id → agents mapping via the module boundary.
      # We exercise top_n_agents with an explicit agent list to avoid coupling
      # to AgentRegistry in unit tests.
      result =
        FormationRateLimiter.top_n_agents(formation_id, 10, [{a1, tool}, {a2, tool}, {a3, tool}])

      assert length(result) == 3
      [first, second, third] = result

      assert first.agent_id == a2
      assert first.used == 7

      assert second.agent_id == a3
      assert second.used == 5

      assert third.agent_id == a1
      assert third.used == 3
    end

    test "respects the N limit" do
      formation_id = unique_formation()
      tool = "Write"

      agents = for i <- 1..5, do: {unique_agent("top-n-#{i}"), tool}

      Enum.each(agents, fn {a, t} -> pump_agent_hits(a, t, Enum.random(1..20)) end)

      result = FormationRateLimiter.top_n_agents(formation_id, 3, agents)
      assert length(result) <= 3
    end

    test "returns correct :used, :tool_name, :agent_id fields in each entry" do
      formation_id = unique_formation()
      tool = "Edit"
      agent = unique_agent("top-fields")

      pump_agent_hits(agent, tool, 4)
      result = FormationRateLimiter.top_n_agents(formation_id, 5, [{agent, tool}])

      assert [entry] = result
      assert %{agent_id: ^agent, tool_name: ^tool, used: 4} = entry
    end

    test "agents with zero usage are excluded from results" do
      formation_id = unique_formation()
      tool = "Read"

      active = unique_agent("top-active")
      idle = unique_agent("top-idle")

      pump_agent_hits(active, tool, 2)
      # idle agent: no hits — bucket is empty (zero)

      result = FormationRateLimiter.top_n_agents(formation_id, 10, [{active, tool}, {idle, tool}])

      agent_ids = Enum.map(result, & &1.agent_id)
      assert active in agent_ids
      refute idle in agent_ids
    end
  end

  # ---------------------------------------------------------------------------
  # rl-s10 — heatmap_data/1
  # ---------------------------------------------------------------------------

  describe "heatmap_data/1 — CP-265 / rl-s10" do
    test "returns empty map when no tools used for formation" do
      formation_id = unique_formation()
      assert FormationRateLimiter.heatmap_data(formation_id) == %{}
    end

    test "computes utilization percentage for a single tool" do
      formation_id = unique_formation()
      tool = "Bash"
      risk_level = :low
      per_agent_limit = Map.get(FormationRateLimiter.risk_limits(), risk_level)

      count = agent_count_for_formation(formation_id)
      budget = FormationRateLimiter.formation_budget(per_agent_limit, count)

      # Pump exactly half the formation budget
      hits = div(budget, 2)
      pump_formation_hits(formation_id, tool, hits)

      heatmap = FormationRateLimiter.heatmap_data(formation_id)

      assert Map.has_key?(heatmap, tool)
      pct = Map.get(heatmap, tool)
      assert is_float(pct) or is_integer(pct)
      assert pct >= 0.0 and pct <= 100.0
    end

    test "returns 100.0 when formation budget fully exhausted" do
      formation_id = unique_formation()
      tool = "FullBash"
      risk_level = :low
      per_agent_limit = Map.get(FormationRateLimiter.risk_limits(), risk_level)

      count = agent_count_for_formation(formation_id)
      budget = FormationRateLimiter.formation_budget(per_agent_limit, count)

      # Exhaust the entire budget
      pump_formation_hits(formation_id, tool, budget)

      heatmap = FormationRateLimiter.heatmap_data(formation_id)
      pct = Map.get(heatmap, tool)
      assert pct == 100.0
    end

    test "tracks multiple tools independently" do
      formation_id = unique_formation()

      pump_formation_hits(formation_id, "ToolA", 10)
      pump_formation_hits(formation_id, "ToolB", 20)

      heatmap = FormationRateLimiter.heatmap_data(formation_id)

      assert Map.has_key?(heatmap, "ToolA")
      assert Map.has_key?(heatmap, "ToolB")

      pct_a = Map.get(heatmap, "ToolA")
      pct_b = Map.get(heatmap, "ToolB")

      # ToolB has more hits so its utilization should be >= ToolA's
      assert pct_b >= pct_a
    end

    test "utilization values are floats clamped between 0.0 and 100.0" do
      formation_id = unique_formation()
      pump_formation_hits(formation_id, "ClampTool", 5)

      heatmap = FormationRateLimiter.heatmap_data(formation_id)

      for {_tool, pct} <- heatmap do
        assert is_number(pct)
        assert pct >= 0.0
        assert pct <= 100.0
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Derive expected agent count the same way the module does (defaults to 1).
  defp agent_count_for_formation(formation_id) do
    FormationRateLimiter.agent_count(formation_id)
  end
end
