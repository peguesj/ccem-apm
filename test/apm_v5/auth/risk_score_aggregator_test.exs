defmodule ApmV5.Auth.RiskScoreAggregatorTest do
  @moduledoc """
  Tests for RiskScoreAggregator — composite session/formation risk scoring.

  Verifies PubSub subscription, score computation formula, and the public
  for_session/for_formation API.

  CP-231 / US-463 — v9.3.0 comp-map2.
  """

  use ExUnit.Case, async: false

  alias ApmV5.Auth.{PolicyDecisionStore, RiskScoreAggregator}

  setup do
    PolicyDecisionStore.clear()
    RiskScoreAggregator.clear()
    :ok
  end

  describe "for_session/1 — PubSub driven update" do
    test "returns nil for unknown session" do
      assert RiskScoreAggregator.for_session("unknown-sess") == nil
    end

    test "picks up a :policy_decision broadcast and exposes score" do
      session_id = "sess-test-#{System.unique_integer([:positive])}"

      # Insert into the store first — the aggregator queries the store on broadcast
      PolicyDecisionStore.record_sync(%{
        session_id: session_id,
        formation_id: nil,
        agent_id: "agent-test",
        tool_name: "Bash",
        risk_level: :high,
        outcome: :allow,
        timestamp: DateTime.utc_now()
      })

      Phoenix.PubSub.broadcast(
        ApmV5.PubSub,
        "auth:decisions",
        {:policy_decision,
         %{
           session_id: session_id,
           formation_id: nil,
           risk_level: :high,
           outcome: :allow,
           timestamp: DateTime.utc_now()
         }}
      )

      # Give the GenServer time to process the message
      :timer.sleep(50)

      agg = RiskScoreAggregator.for_session(session_id)
      assert agg != nil
      assert agg.tool_call_count == 1
      assert agg.level in [:none, :low, :medium, :high, :critical]
      assert agg.score >= 0.0 and agg.score <= 4.0
    end

    test "score increases when denials accumulate" do
      session_id = "sess-denials-#{System.unique_integer([:positive])}"
      now = DateTime.utc_now()

      # Insert directly into PolicyDecisionStore so the rolling window query works
      for _ <- 1..5 do
        PolicyDecisionStore.record_sync(%{
          session_id: session_id,
          formation_id: nil,
          agent_id: "agent-test",
          tool_name: "Bash",
          risk_level: :high,
          outcome: :deny,
          timestamp: now
        })
      end

      # Trigger aggregation via a final broadcast
      Phoenix.PubSub.broadcast(
        ApmV5.PubSub,
        "auth:decisions",
        {:policy_decision,
         %{
           session_id: session_id,
           formation_id: nil,
           risk_level: :high,
           outcome: :deny,
           timestamp: now
         }}
      )

      :timer.sleep(50)

      agg = RiskScoreAggregator.for_session(session_id)
      assert agg != nil
      # denial_rate = 1.0 → denial_boost = 1.5; base 3 (high) + 1.5 > 4, capped at 4
      assert agg.score > 3.0
      assert agg.denial_rate == 1.0
    end
  end

  describe "for_formation/1" do
    test "returns nil for unknown formation" do
      assert RiskScoreAggregator.for_formation("fmt-unknown") == nil
    end

    test "aggregates across a formation_id" do
      formation_id = "fmt-test-#{System.unique_integer([:positive])}"
      now = DateTime.utc_now()

      PolicyDecisionStore.record_sync(%{
        session_id: "s1",
        formation_id: formation_id,
        agent_id: "a1",
        tool_name: "Write",
        risk_level: :critical,
        outcome: :deny,
        timestamp: now
      })

      Phoenix.PubSub.broadcast(
        ApmV5.PubSub,
        "auth:decisions",
        {:policy_decision,
         %{
           session_id: "s1",
           formation_id: formation_id,
           risk_level: :critical,
           outcome: :deny,
           timestamp: now
         }}
      )

      :timer.sleep(50)

      agg = RiskScoreAggregator.for_formation(formation_id)
      assert agg != nil
      assert agg.critical_count >= 1
    end
  end

  describe "top_sessions/1" do
    test "returns a list" do
      assert is_list(RiskScoreAggregator.top_sessions(5))
    end

    test "limits results" do
      assert length(RiskScoreAggregator.top_sessions(1)) <= 1
    end
  end

  describe "top_formations/1" do
    test "returns a list" do
      assert is_list(RiskScoreAggregator.top_formations(5))
    end
  end
end
