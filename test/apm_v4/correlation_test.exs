defmodule ApmV4.CorrelationTest do
  use ExUnit.Case, async: true

  alias ApmV4.Correlation

  describe "generate/0" do
    test "returns a valid UUID v4 string" do
      id = Correlation.generate()
      assert is_binary(id)
      assert String.match?(id, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
    end
  end

  describe "put/1 and get/0" do
    test "roundtrip stores and retrieves correlation ID" do
      id = Correlation.generate()
      assert :ok = Correlation.put(id)
      assert Correlation.get() == id
    end

    test "get returns nil when not set" do
      # Run in a fresh process to ensure clean process dictionary
      task = Task.async(fn -> Correlation.get() end)
      assert Task.await(task) == nil
    end
  end

  describe "with_correlation/2" do
    test "sets correlation ID for the duration of the function" do
      outer_id = "outer-id"
      inner_id = "inner-id"
      Correlation.put(outer_id)

      result =
        Correlation.with_correlation(inner_id, fn ->
          assert Correlation.get() == inner_id
          :ok
        end)

      assert result == :ok
      assert Correlation.get() == outer_id
    end

    test "restores nil when no previous ID was set" do
      task =
        Task.async(fn ->
          Correlation.with_correlation("temp-id", fn ->
            assert Correlation.get() == "temp-id"
          end)

          Correlation.get()
        end)

      assert Task.await(task) == nil
    end
  end
end
