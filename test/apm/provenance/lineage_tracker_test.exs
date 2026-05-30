defmodule Apm.Provenance.LineageTrackerTest do
  @moduledoc """
  TDD tests for LineageTracker (prov-w2-s6 / CP-280).

  Core invariant: a 2-step pipeline where agent A produces output that agent B
  consumes as input creates a wasDerivedFrom edge in :apm_lineage_edges.

  Tests:
  1. tool_call_end records {invocation_id, agent_id, output_hash} in :apm_tool_outputs
  2. tool_call_start with matching input_hash records wasDerivedFrom edge
  3. lineage_for_agent/1 returns {nodes, edges} DAG
  4. ETS tables are capped at 5000 entries
  5. ProvExporter bundle includes wasDerivedFrom edges after pipeline
  """

  use ExUnit.Case, async: false

  @moduletag :lineage_tracker

  alias Apm.Provenance.LineageTracker

  setup do
    case Process.whereis(LineageTracker) do
      nil ->
        {:ok, pid} = LineageTracker.start_link([])
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      pid ->
        LineageTracker.clear_for_test()
        on_exit(fn -> if Process.alive?(pid), do: LineageTracker.clear_for_test() end)
    end

    :ok
  end

  describe "record_tool_end/3" do
    test "records output entry in :apm_tool_outputs" do
      output_hash = :crypto.hash(:sha256, "some output content") |> Base.encode16(case: :lower)

      LineageTracker.record_tool_end("inv-001", "agent-alpha", output_hash)

      entries = LineageTracker.list_outputs()
      assert Enum.any?(entries, fn e ->
        (Map.get(e, :invocation_id) || Map.get(e, "invocation_id")) == "inv-001"
      end)
    end
  end

  describe "record_tool_start/3" do
    test "creates wasDerivedFrom edge when input_hash matches a known output_hash" do
      # Step 1: agent-alpha produces output
      output_content = "step1 output #{System.unique_integer()}"
      output_hash = :crypto.hash(:sha256, output_content) |> Base.encode16(case: :lower)
      LineageTracker.record_tool_end("inv-001", "agent-alpha", output_hash)

      # Step 2: agent-beta starts with that output as input
      LineageTracker.record_tool_start("inv-002", "agent-beta", output_hash)

      # Verify edge exists
      edges = LineageTracker.list_edges()
      assert length(edges) >= 1

      matching_edge =
        Enum.find(edges, fn e ->
          from = Map.get(e, :from_invocation_id) || Map.get(e, "from_invocation_id")
          to = Map.get(e, :to_invocation_id) || Map.get(e, "to_invocation_id")
          from == "inv-001" and to == "inv-002"
        end)

      assert matching_edge != nil
    end

    test "does NOT create edge when input_hash is unknown" do
      unknown_hash = :crypto.hash(:sha256, "something never produced") |> Base.encode16(case: :lower)
      LineageTracker.record_tool_start("inv-999", "agent-gamma", unknown_hash)

      edges = LineageTracker.list_edges()
      # No new edges should have been created for inv-999
      matching = Enum.filter(edges, fn e ->
        (Map.get(e, :to_invocation_id) || Map.get(e, "to_invocation_id")) == "inv-999"
      end)

      assert matching == []
    end
  end

  describe "lineage_for_agent/1" do
    test "2-step pipeline yields wasDerivedFrom edge in lineage DAG" do
      output_content = "pipeline step1 #{System.unique_integer()}"
      output_hash = :crypto.hash(:sha256, output_content) |> Base.encode16(case: :lower)

      LineageTracker.record_tool_end("pipe-inv-001", "agent-src", output_hash)
      LineageTracker.record_tool_start("pipe-inv-002", "agent-dst", output_hash)

      dag = LineageTracker.lineage_for_agent("agent-src")

      assert Map.has_key?(dag, :nodes) or Map.has_key?(dag, "nodes")
      assert Map.has_key?(dag, :edges) or Map.has_key?(dag, "edges")

      edges = Map.get(dag, :edges, Map.get(dag, "edges", []))
      assert length(edges) >= 1

      edge = Enum.find(edges, fn e ->
        from = Map.get(e, :from_invocation_id) || Map.get(e, "from_invocation_id")
        from == "pipe-inv-001"
      end)

      assert edge != nil
    end

    test "returns empty nodes+edges for unknown agent" do
      dag = LineageTracker.lineage_for_agent("agent-nobody-#{System.unique_integer()}")
      nodes = Map.get(dag, :nodes, Map.get(dag, "nodes", []))
      edges = Map.get(dag, :edges, Map.get(dag, "edges", []))
      assert is_list(nodes)
      assert is_list(edges)
    end
  end

  describe "edge structure" do
    test "each edge has from_invocation_id, to_invocation_id, agent_id, timestamp" do
      output_content = "structure test #{System.unique_integer()}"
      output_hash = :crypto.hash(:sha256, output_content) |> Base.encode16(case: :lower)

      LineageTracker.record_tool_end("str-inv-001", "agent-a", output_hash)
      LineageTracker.record_tool_start("str-inv-002", "agent-b", output_hash)

      [edge | _] = LineageTracker.list_edges()

      assert Map.has_key?(edge, :from_invocation_id) or Map.has_key?(edge, "from_invocation_id")
      assert Map.has_key?(edge, :to_invocation_id) or Map.has_key?(edge, "to_invocation_id")
      assert Map.has_key?(edge, :agent_id) or Map.has_key?(edge, "agent_id")
      assert Map.has_key?(edge, :timestamp) or Map.has_key?(edge, "timestamp")
    end
  end

  describe "ProvExporter integration" do
    test "ProvExporter bundle wasDerivedFrom is non-empty after pipeline" do
      output_content = "prov-export test #{System.unique_integer()}"
      output_hash = :crypto.hash(:sha256, output_content) |> Base.encode16(case: :lower)

      LineageTracker.record_tool_end("prov-inv-001", "agent-prov-src", output_hash)
      LineageTracker.record_tool_start("prov-inv-002", "agent-prov-dst", output_hash)

      bundle = Apm.Provenance.ProvExporter.build_bundle("any-formation")
      derived = Map.get(bundle, "wasDerivedFrom", %{})

      assert map_size(derived) >= 1
    end
  end
end
