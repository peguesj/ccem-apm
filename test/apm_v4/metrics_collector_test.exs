defmodule ApmV4.MetricsCollectorTest do
  use ExUnit.Case, async: false

  alias ApmV4.MetricsCollector

  setup do
    ApmV4.GenServerHelpers.ensure_processes_alive()
    MetricsCollector.clear_all()
    ApmV4.AgentRegistry.clear_all()
    :ok
  end

  describe "record/3" do
    test "accumulates metrics into the current minute bucket" do
      MetricsCollector.record("agent-1", :error_count, 1)
      MetricsCollector.record("agent-1", :error_count, 2)
      MetricsCollector.record("agent-1", :token_input, 500)
      :timer.sleep(50)

      metrics = MetricsCollector.get_agent_metrics("agent-1")
      assert length(metrics) == 1

      [m] = metrics
      assert m.error_count == 3
      assert m.token_input == 500
      assert m.agent_id == "agent-1"
    end

    test "averages response_time_ms across recordings" do
      MetricsCollector.record("agent-2", :response_time_ms, 100.0)
      MetricsCollector.record("agent-2", :response_time_ms, 200.0)
      :timer.sleep(50)

      [m] = MetricsCollector.get_agent_metrics("agent-2")
      assert_in_delta m.response_time_ms, 150.0, 0.1
    end
  end

  describe "get_agent_metrics/2" do
    test "returns recorded data for an agent" do
      MetricsCollector.record("agent-3", :tool_calls, 5)
      :timer.sleep(50)

      results = MetricsCollector.get_agent_metrics("agent-3")
      assert length(results) >= 1
      assert hd(results).tool_calls == 5
    end

    test "returns empty list for unknown agent" do
      assert MetricsCollector.get_agent_metrics("nonexistent") == []
    end

    test "respects limit option" do
      MetricsCollector.record("agent-4", :error_count, 1)
      :timer.sleep(50)

      results = MetricsCollector.get_agent_metrics("agent-4", limit: 1)
      assert length(results) <= 1
    end
  end

  describe "get_fleet_metrics/0" do
    test "returns aggregates after recomputation" do
      MetricsCollector.record("fleet-a", :token_input, 1000)
      MetricsCollector.record("fleet-a", :error_count, 2)
      MetricsCollector.record("fleet-b", :token_input, 500)
      :timer.sleep(50)

      MetricsCollector.recompute_fleet_metrics()

      fleet = MetricsCollector.get_fleet_metrics()
      assert fleet.total_agents == 2
      assert fleet.total_tokens_input == 1500
      assert fleet.total_errors == 2
      assert is_binary(fleet.computed_at)
    end

    test "returns empty map before any computation" do
      result = MetricsCollector.get_fleet_metrics()
      assert is_map(result)
    end
  end

  describe "compute_health_score/1" do
    test "returns a score between 0 and 100" do
      MetricsCollector.record("health-agent", :error_count, 1)
      MetricsCollector.record("health-agent", :response_time_ms, 50.0)
      :timer.sleep(50)

      score = MetricsCollector.compute_health_score("health-agent")
      assert is_float(score)
      assert score >= 0.0
      assert score <= 100.0
    end

    test "agent with zero errors scores higher than agent with many errors" do
      ApmV4.AgentRegistry.register_agent("good-agent", %{status: "running"})
      ApmV4.AgentRegistry.register_agent("bad-agent", %{status: "running"})

      MetricsCollector.record("good-agent", :error_count, 0)
      MetricsCollector.record("bad-agent", :error_count, 10)
      :timer.sleep(50)

      good_score = MetricsCollector.compute_health_score("good-agent")
      bad_score = MetricsCollector.compute_health_score("bad-agent")
      assert good_score > bad_score
    end
  end

  describe "prune/0" do
    test "removes data older than 24 hours" do
      old_bucket = div(System.system_time(:second) - 172_800, 60)
      key = {"old-agent", old_bucket}
      metrics = %{
        response_time_ms: 0.0, response_time_count: 0,
        error_count: 5, token_input: 100, token_output: 50,
        tool_calls: 2, task_duration_ms: 0.0, task_duration_count: 0
      }
      :ets.insert(:apm_agent_metrics, {key, metrics})

      MetricsCollector.record("old-agent", :error_count, 1)
      :timer.sleep(50)

      assert :ets.lookup(:apm_agent_metrics, key) != []

      MetricsCollector.prune()

      assert :ets.lookup(:apm_agent_metrics, key) == []

      current = MetricsCollector.get_agent_metrics("old-agent")
      assert length(current) >= 1
    end
  end

  describe "PubSub broadcast" do
    test "broadcasts fleet_metrics_updated on recompute" do
      Phoenix.PubSub.subscribe(ApmV4.PubSub, "apm:metrics")

      MetricsCollector.record("pub-agent", :token_input, 100)
      :timer.sleep(50)

      MetricsCollector.recompute_fleet_metrics()

      assert_receive {:fleet_metrics_updated, metrics}, 1000
      assert is_map(metrics)
      assert Map.has_key?(metrics, :total_agents)
    end
  end
end
