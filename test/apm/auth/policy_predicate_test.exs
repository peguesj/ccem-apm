defmodule Apm.Auth.PolicyPredicateTest do
  @moduledoc """
  TDD tests for CP-286 (auth-s3-c): PolicyPredicate DSL.

  Covers all 4 predicate types with positive + negative cases,
  and integration into PolicyEngine.evaluate/3.

  Run with: mix test --only auth_ext
  """

  use ExUnit.Case, async: true

  @moduletag :auth_ext

  alias Apm.Auth.PolicyPredicate

  # ---------------------------------------------------------------------------
  # time_window predicate
  # ---------------------------------------------------------------------------

  describe "time_window predicate" do
    test "matches when current hour is inside the window" do
      # Window: all hours 0..23 — always matches
      pred = %PolicyPredicate{type: :time_window, params: %{from_hour: 0, to_hour: 23}}
      assert PolicyPredicate.evaluate(pred, %{}) == :match
    end

    test "matches when current hour equals from_hour" do
      now = DateTime.utc_now()
      pred = %PolicyPredicate{
        type: :time_window,
        params: %{from_hour: now.hour, to_hour: now.hour}
      }

      assert PolicyPredicate.evaluate(pred, %{}) == :match
    end

    test "no_match when window is effectively impossible (from > to on a narrow range)" do
      # e.g., from_hour=25 (invalid), treated as no_match via guard
      pred = %PolicyPredicate{type: :time_window, params: %{from_hour: 25, to_hour: 26}}
      assert PolicyPredicate.evaluate(pred, %{}) == :no_match
    end

    test "no_match when window is empty slice that excludes current hour" do
      now = DateTime.utc_now()
      # Pick a window guaranteed not to include now.hour
      # Use from_hour = to_hour = (now.hour + 12) mod 24
      other_hour = rem(now.hour + 12, 24)
      pred = %PolicyPredicate{
        type: :time_window,
        params: %{from_hour: other_hour, to_hour: other_hour}
      }

      expected = if now.hour == other_hour, do: :match, else: :no_match
      assert PolicyPredicate.evaluate(pred, %{}) == expected
    end
  end

  # ---------------------------------------------------------------------------
  # env_match predicate
  # ---------------------------------------------------------------------------

  describe "env_match predicate" do
    test "matches when context env equals predicate env" do
      pred = %PolicyPredicate{type: :env_match, params: %{env: :prod}}
      assert PolicyPredicate.evaluate(pred, %{env: :prod}) == :match
    end

    test "no_match when context env differs" do
      pred = %PolicyPredicate{type: :env_match, params: %{env: :prod}}
      assert PolicyPredicate.evaluate(pred, %{env: :staging}) == :no_match
    end

    test "no_match when context has no env key" do
      pred = %PolicyPredicate{type: :env_match, params: %{env: :prod}}
      assert PolicyPredicate.evaluate(pred, %{}) == :no_match
    end

    test "matches :dev env" do
      pred = %PolicyPredicate{type: :env_match, params: %{env: :dev}}
      assert PolicyPredicate.evaluate(pred, %{env: :dev}) == :match
    end
  end

  # ---------------------------------------------------------------------------
  # path_glob predicate
  # ---------------------------------------------------------------------------

  describe "path_glob predicate" do
    test "matches .env file with **/*.env glob" do
      pred = %PolicyPredicate{type: :path_glob, params: %{glob: "**/*.env"}}
      assert PolicyPredicate.evaluate(pred, %{path: "/project/.env"}) == :match
    end

    test "matches nested .env file" do
      pred = %PolicyPredicate{type: :path_glob, params: %{glob: "**/*.env"}}
      assert PolicyPredicate.evaluate(pred, %{path: "/deep/nested/path/.env"}) == :match
    end

    test "no_match for non-matching extension" do
      pred = %PolicyPredicate{type: :path_glob, params: %{glob: "**/*.env"}}
      assert PolicyPredicate.evaluate(pred, %{path: "/project/README.md"}) == :no_match
    end

    test "matches exact filename" do
      pred = %PolicyPredicate{type: :path_glob, params: %{glob: "secrets.json"}}
      assert PolicyPredicate.evaluate(pred, %{path: "secrets.json"}) == :match
    end

    test "no_match when context has no path key" do
      pred = %PolicyPredicate{type: :path_glob, params: %{glob: "**/*.env"}}
      assert PolicyPredicate.evaluate(pred, %{}) == :no_match
    end

    test "matches config/**/*.yml pattern" do
      pred = %PolicyPredicate{type: :path_glob, params: %{glob: "config/**/*.yml"}}
      assert PolicyPredicate.evaluate(pred, %{path: "config/production/app.yml"}) == :match
    end

    test "no_match when path does not satisfy directory prefix" do
      pred = %PolicyPredicate{type: :path_glob, params: %{glob: "config/**/*.yml"}}
      assert PolicyPredicate.evaluate(pred, %{path: "other/production/app.yml"}) == :no_match
    end
  end

  # ---------------------------------------------------------------------------
  # formation_role predicate
  # ---------------------------------------------------------------------------

  describe "formation_role predicate" do
    test "matches when context formation_role equals predicate role" do
      pred = %PolicyPredicate{type: :formation_role, params: %{role: :orchestrator}}
      assert PolicyPredicate.evaluate(pred, %{formation_role: :orchestrator}) == :match
    end

    test "no_match when context formation_role differs" do
      pred = %PolicyPredicate{type: :formation_role, params: %{role: :orchestrator}}
      assert PolicyPredicate.evaluate(pred, %{formation_role: :swarm_agent}) == :no_match
    end

    test "no_match when context has no formation_role key" do
      pred = %PolicyPredicate{type: :formation_role, params: %{role: :orchestrator}}
      assert PolicyPredicate.evaluate(pred, %{}) == :no_match
    end

    test "matches squadron_lead role" do
      pred = %PolicyPredicate{type: :formation_role, params: %{role: :squadron_lead}}
      assert PolicyPredicate.evaluate(pred, %{formation_role: :squadron_lead}) == :match
    end
  end

  # ---------------------------------------------------------------------------
  # evaluate_all/2 — all predicates must match
  # ---------------------------------------------------------------------------

  describe "evaluate_all/2" do
    test "empty predicate list always matches" do
      assert PolicyPredicate.evaluate_all([], %{}) == :match
    end

    test "all predicates matching returns :match" do
      preds = [
        %PolicyPredicate{type: :env_match, params: %{env: :prod}},
        %PolicyPredicate{type: :formation_role, params: %{role: :orchestrator}}
      ]

      assert PolicyPredicate.evaluate_all(preds, %{env: :prod, formation_role: :orchestrator}) == :match
    end

    test "one failing predicate returns :no_match" do
      preds = [
        %PolicyPredicate{type: :env_match, params: %{env: :prod}},
        %PolicyPredicate{type: :formation_role, params: %{role: :orchestrator}}
      ]

      assert PolicyPredicate.evaluate_all(preds, %{env: :staging, formation_role: :orchestrator}) == :no_match
    end
  end

  # ---------------------------------------------------------------------------
  # Unknown predicate type — graceful fallback
  # ---------------------------------------------------------------------------

  describe "unknown predicate type" do
    test "returns :no_match for unrecognised predicate type" do
      pred = %PolicyPredicate{type: :unknown_future_type, params: %{}}
      assert PolicyPredicate.evaluate(pred, %{}) == :no_match
    end
  end

  # ---------------------------------------------------------------------------
  # PolicyEngine integration — predicates gate permanent rules
  # ---------------------------------------------------------------------------

  describe "PolicyEngine.evaluate/3 with predicates" do
    alias Apm.Auth.PolicyEngine

    test "always_allow rule fires when env_match predicate matches" do
      pred = %PolicyPredicate{type: :env_match, params: %{env: :prod}}
      context = %{policy_rule: :always_allow, predicates: [pred], env: :prod}
      decision = PolicyEngine.evaluate("Write", "agent", context)
      assert decision.allowed == true
      assert decision.reason == :always_allow_rule
    end

    test "always_allow rule is bypassed when env_match predicate does not match" do
      pred = %PolicyPredicate{type: :env_match, params: %{env: :prod}}
      # env is :dev so predicate fails — rule does not fire, normal eval applies
      context = %{policy_rule: :always_allow, predicates: [pred], env: :dev}
      decision = PolicyEngine.evaluate("Read", "agent", context)
      # "Read" has :none risk so it still gets permitted — but NOT via always_allow_rule
      assert decision.allowed == true
      refute decision.reason == :always_allow_rule
    end

    test "always_deny rule fires when formation_role predicate matches" do
      pred = %PolicyPredicate{type: :formation_role, params: %{role: :swarm_agent}}
      context = %{policy_rule: :always_deny, predicates: [pred], formation_role: :swarm_agent}
      decision = PolicyEngine.evaluate("Bash", "agent", context)
      assert decision.allowed == false
      assert decision.reason == :always_deny_rule
    end

    test "always_deny rule is bypassed when formation_role predicate does not match" do
      pred = %PolicyPredicate{type: :formation_role, params: %{role: :swarm_agent}}
      context = %{policy_rule: :always_deny, predicates: [pred], formation_role: :orchestrator}
      decision = PolicyEngine.evaluate("Read", "agent", context)
      # predicate does not match — deny rule inactive, Read at :none is auto-permitted
      assert decision.allowed == true
      refute decision.reason == :always_deny_rule
    end

    test "empty predicates list does not affect permanent rule" do
      context = %{policy_rule: :always_allow, predicates: []}
      decision = PolicyEngine.evaluate("Write", "agent", context)
      assert decision.allowed == true
      assert decision.reason == :always_allow_rule
    end
  end
end
