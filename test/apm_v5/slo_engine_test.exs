defmodule ApmV5.SloEngineTest do
  use ExUnit.Case, async: false

  alias ApmV5.SloEngine

  setup do
    SloEngine.clear_all()
    :ok
  end

  describe "get_all_slis/0" do
    test "returns 5 SLIs with defaults" do
      slis = SloEngine.get_all_slis()
      assert length(slis) == 5

      names = Enum.map(slis, & &1.name) |> Enum.sort()

      assert names == [
               :agent_availability,
               :api_latency_p99,
               :error_free_rate,
               :fleet_heartbeat_health,
               :task_completion_rate
             ]

      for sli <- slis do
        assert sli.current_value == 100.0
        assert sli.status == :met
        assert sli.total_events == 0
      end
    end
  end

  describe "record_event/2" do
    test "updates SLI value on success" do
      :ok = SloEngine.record_event(:error_free_rate, :ok)
      sli = SloEngine.get_sli(:error_free_rate)
      assert sli.current_value == 100.0
      assert sli.total_events == 1
      assert sli.error_events == 0
    end

    test "updates SLI value on error" do
      :ok = SloEngine.record_event(:error_free_rate, :ok)
      :ok = SloEngine.record_event(:error_free_rate, :error)
      sli = SloEngine.get_sli(:error_free_rate)
      assert sli.current_value == 50.0
      assert sli.total_events == 2
      assert sli.error_events == 1
      assert sli.status == :breached
    end

    test "returns error for unknown SLI" do
      assert {:error, :unknown_sli} = SloEngine.record_event(:nonexistent, :ok)
    end
  end

  describe "get_error_budget/1" do
    test "computes remaining budget" do
      budget = SloEngine.get_error_budget(:error_free_rate)
      assert budget.name == :error_free_rate
      assert budget.target == 97.0
      # No events yet, budget should be full
      assert budget.budget_remaining_pct == 100.0
    end

    test "budget decreases after errors" do
      # Record 100 events, 5 errors (5% error rate, budget is 3%)
      for _ <- 1..95, do: SloEngine.record_event(:error_free_rate, :ok)
      for _ <- 1..5, do: SloEngine.record_event(:error_free_rate, :error)

      budget = SloEngine.get_error_budget(:error_free_rate)
      # Budget allowed = 3% of 100 = 3 errors, we have 5
      assert budget.budget_remaining == 0.0
    end

    test "returns nil for unknown SLI" do
      assert SloEngine.get_error_budget(:nonexistent) == nil
    end
  end

  describe "PubSub transitions" do
    test "broadcasts when SLI transitions from met to breached" do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:slo")

      # Force a breach: error_free_rate target is 97%, so >3% errors triggers breach
      for _ <- 1..3, do: SloEngine.record_event(:error_free_rate, :error)

      # With 3 errors out of 3 events = 0% success, should be breached
      assert_receive {:slo_transition, :error_free_rate, :met, :breached}, 1000
    end
  end

  describe "get_history/2" do
    test "returns data after snapshot" do
      SloEngine.record_event(:agent_availability, :ok)
      SloEngine.snapshot_now()

      history = SloEngine.get_history(:agent_availability, 1)
      assert length(history) >= 1
      [entry | _] = history
      assert entry.name == :agent_availability
      assert entry.value == 100.0
    end
  end
end
