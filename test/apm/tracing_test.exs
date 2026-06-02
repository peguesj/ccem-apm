defmodule Apm.TracingTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for Apm.Tracing span wrappers.

  Because the OTel SDK runs as a no-op (no OTLP exporter in the test env),
  we verify that:
    1. Each wrapper returns the value of the supplied function.
    2. Each wrapper propagates exceptions from the supplied function.
    3. The wrappers are composable (nested spans do not raise).
  """

  alias Apm.Tracing

  describe "with_agent_span/3" do
    test "returns function result" do
      result = Tracing.with_agent_span("agent-1", "fmt-001", fn -> :agent_ok end)
      assert result == :agent_ok
    end

    test "propagates tagged-tuple results" do
      result = Tracing.with_agent_span("agent-2", "fmt-002", fn -> {:ok, 42} end)
      assert result == {:ok, 42}
    end

    test "propagates exceptions" do
      assert_raise RuntimeError, "boom", fn ->
        Tracing.with_agent_span("agent-3", nil, fn -> raise "boom" end)
      end
    end
  end

  describe "with_tool_span/3" do
    test "returns function result" do
      result = Tracing.with_tool_span("Bash", "sess-001", fn -> :tool_ok end)
      assert result == :tool_ok
    end

    test "accepts nil session_id" do
      assert :ok = Tracing.with_tool_span("Read", nil, fn -> :ok end)
    end
  end

  describe "with_llm_span/5" do
    test "returns function result" do
      result = Tracing.with_llm_span("claude-sonnet-4-6", 100, 200, fn -> :llm_ok end)
      assert result == :llm_ok
    end

    test "accepts cache token opts" do
      result =
        Tracing.with_llm_span("claude-opus-4", 500, 100, fn -> :cached end,
          cache_read_tokens: 400,
          cache_creation_tokens: 50
        )

      assert result == :cached
    end
  end

  describe "with_formation_span/3" do
    test "returns function result" do
      result = Tracing.with_formation_span("fmt-100", 3, fn -> :formation_ok end)
      assert result == :formation_ok
    end

    test "propagates exceptions" do
      assert_raise ArgumentError, fn ->
        Tracing.with_formation_span("fmt-101", 1, fn -> raise ArgumentError end)
      end
    end
  end

  describe "composition" do
    test "nested spans do not raise" do
      result =
        Tracing.with_formation_span("fmt-200", 1, fn ->
          Tracing.with_agent_span("agent-nested", "fmt-200", fn ->
            Tracing.with_tool_span("Write", "sess-200", fn ->
              Tracing.with_llm_span("claude-sonnet-4-6", 10, 20, fn -> :nested_ok end)
            end)
          end)
        end)

      assert result == :nested_ok
    end
  end
end
