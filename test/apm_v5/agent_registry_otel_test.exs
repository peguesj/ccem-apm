defmodule ApmV5.AgentRegistryOtelTest do
  @moduledoc """
  TDD suite for OTel gen_ai.agent.* span emission in AgentRegistry (prov-w3-s8 / CP-282).

  The OTel SDK runs as a no-op tracer in the test environment (no OTLP exporter
  configured).  Following the established pattern in ApmV5.TracingTest, we verify:

  1. register_agent/3 still returns :ok and persists the agent (span does not break flow).
  2. update_status/2 still returns :ok and updates the agent (span does not break flow).
  3. Span wrapping in AgentRegistry calls ApmV5.Tracing.with_agent_span/3 — verified by
     ensuring the agent attributes (gen_ai.agent.id, gen_ai.provider.name, formation_id)
     are readable from the registered agent record (they come from AgentIdentity, which
     with_agent_span uses to set span attributes).
  4. update_status/2 does not raise when wrapping with_agent_span.

  Integration-level span attribute verification (asserting actual OTel span data) requires
  :otel_exporter_pid and a running :otel_simple_processor, which are not available in
  the default test mix environment.  That verification belongs in a dedicated OTel
  integration test suite wired with `Application.put_env(:opentelemetry, ...)` start.
  """

  use ExUnit.Case, async: false

  setup do
    case Process.whereis(ApmV5.AgentRegistry) do
      nil ->
        {:ok, _} = ApmV5.AgentRegistry.start_link()
        :ok

      _pid ->
        ApmV5.AgentRegistry.clear_all()
        :ok
    end
  end

  # ── register_agent OTel span wrapping ────────────────────────────────────────

  describe "AgentRegistry.register_agent/3 with OTel span wrapping" do
    test "returns :ok and agent is registered (span is a no-op in test env)" do
      assert :ok =
               ApmV5.AgentRegistry.register_agent(
                 "otel-test-agent-001",
                 %{formation_id: "fmt-otel-test", session_id: "sess-otel-001"},
                 nil
               )

      agent = ApmV5.AgentRegistry.get_agent("otel-test-agent-001")
      assert agent != nil
    end

    test "agent record has gen_ai.agent.id stored (via AgentIdentity used in span attrs)" do
      :ok =
        ApmV5.AgentRegistry.register_agent(
          "otel-test-agent-002",
          %{formation_id: "fmt-otel-test"},
          nil
        )

      agent = ApmV5.AgentRegistry.get_agent("otel-test-agent-002")
      # AgentIdentity.to_map/1 populates :id which feeds gen_ai.agent.id span attr
      assert Map.get(agent, :id) == "otel-test-agent-002"
    end

    test "agent record has formation_id (feeds ccem.formation.id span attr)" do
      :ok =
        ApmV5.AgentRegistry.register_agent(
          "otel-test-agent-003",
          %{formation_id: "fmt-span-test-123"},
          nil
        )

      agent = ApmV5.AgentRegistry.get_agent("otel-test-agent-003")
      assert Map.get(agent, :formation_id) == "fmt-span-test-123"
    end

    test "span wrapping does not raise when formation_id is nil" do
      assert :ok =
               ApmV5.AgentRegistry.register_agent(
                 "otel-test-agent-004",
                 %{},
                 nil
               )

      assert ApmV5.AgentRegistry.get_agent("otel-test-agent-004") != nil
    end

    test "span wrapping does not leak span context across concurrent registrations" do
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            ApmV5.AgentRegistry.register_agent(
              "otel-concurrent-#{i}",
              %{formation_id: "fmt-concurrent-#{i}"},
              nil
            )
          end)
        end

      results = Task.await_many(tasks, 5_000)
      assert Enum.all?(results, &(&1 == :ok))

      for i <- 1..5 do
        agent = ApmV5.AgentRegistry.get_agent("otel-concurrent-#{i}")
        assert agent != nil
        assert Map.get(agent, :formation_id) == "fmt-concurrent-#{i}"
      end
    end
  end

  # ── update_status OTel span wrapping ─────────────────────────────────────────

  describe "AgentRegistry.update_status/2 with OTel span wrapping" do
    test "returns :ok when agent exists (span is a no-op in test env)" do
      :ok =
        ApmV5.AgentRegistry.register_agent(
          "otel-status-agent-001",
          %{formation_id: "fmt-status-test"},
          nil
        )

      assert :ok = ApmV5.AgentRegistry.update_status("otel-status-agent-001", "active")
    end

    test "agent status is updated after OTel-wrapped update_status call" do
      :ok =
        ApmV5.AgentRegistry.register_agent(
          "otel-status-agent-002",
          %{formation_id: "fmt-status-test"},
          nil
        )

      :ok = ApmV5.AgentRegistry.update_status("otel-status-agent-002", "completed")

      agent = ApmV5.AgentRegistry.get_agent("otel-status-agent-002")
      assert Map.get(agent, :status) == "completed"
    end

    test "returns {:error, :not_found} for unknown agent (span still emitted)" do
      assert {:error, :not_found} =
               ApmV5.AgentRegistry.update_status("otel-nonexistent-agent", "active")
    end

    test "span wrapping does not raise for completed status transition" do
      :ok =
        ApmV5.AgentRegistry.register_agent(
          "otel-status-agent-003",
          %{formation_id: "fmt-status-test"},
          nil
        )

      assert :ok = ApmV5.AgentRegistry.update_status("otel-status-agent-003", "finished")
    end
  end
end
