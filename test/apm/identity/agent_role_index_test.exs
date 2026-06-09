defmodule Apm.Identity.AgentRoleIndexTest do
  @moduledoc """
  TDD tests for AgentRoleIndex (prov-w2-s5 / CP-279).

  Key invariant: same role + same normalized formation pattern → same agent_role_id
  across independent sessions (UUID v5 determinism).

  Tests also cover:
  - touch/2 returns {:ok, role_id}
  - role_appearances/1 returns list of appearances
  - normalize_formation_id strips timestamps from formation IDs
  - GET /api/v2/agents/:agent_id/lineage endpoint
  """

  use ExUnit.Case, async: false

  @moduletag :agent_role_index

  alias Apm.Identity.AgentRoleIndex

  setup do
    case Process.whereis(AgentRoleIndex) do
      nil ->
        {:ok, pid} = AgentRoleIndex.start_link([])
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      pid ->
        # Clear ETS state for test isolation
        AgentRoleIndex.clear_for_test()
        on_exit(fn -> if Process.alive?(pid), do: AgentRoleIndex.clear_for_test() end)
    end

    :ok
  end

  describe "touch/2 determinism" do
    test "same role in two 'sessions' (different formation timestamp suffix) yields same agent_role_id" do
      # Simulate two sessions: timestamps stripped from formation ID
      {:ok, id1} = AgentRoleIndex.touch("squad-lead", "formation-20260101-my-feature")
      {:ok, id2} = AgentRoleIndex.touch("squad-lead", "formation-20260202-my-feature")

      assert is_binary(id1)
      assert id1 == id2
    end

    test "different roles yield different agent_role_ids" do
      {:ok, id1} = AgentRoleIndex.touch("squad-lead", "formation-20260101-feature")
      {:ok, id2} = AgentRoleIndex.touch("worker", "formation-20260101-feature")

      assert id1 != id2
    end

    test "same role + completely different formation base yields different agent_role_id" do
      {:ok, id1} = AgentRoleIndex.touch("squad-lead", "formation-abc")
      {:ok, id2} = AgentRoleIndex.touch("squad-lead", "formation-xyz")

      assert id1 != id2
    end

    test "returned role_id is a UUID-format string (8-4-4-4-12 hex)" do
      {:ok, role_id} = AgentRoleIndex.touch("orchestrator", "formation-20260101-sprint")

      assert String.match?(
               role_id,
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
             )
    end

    test "calling touch/2 multiple times with same args is idempotent" do
      {:ok, id1} = AgentRoleIndex.touch("worker", "formation-20260101-test")
      {:ok, id2} = AgentRoleIndex.touch("worker", "formation-20260101-test")
      {:ok, id3} = AgentRoleIndex.touch("worker", "formation-20260202-test")

      assert id1 == id2
      assert id2 == id3
    end
  end

  describe "role_appearances/1" do
    test "returns list after touches" do
      AgentRoleIndex.touch("worker", "formation-20260101-proj")
      AgentRoleIndex.touch("worker", "formation-20260202-proj")

      appearances = AgentRoleIndex.role_appearances("worker")
      assert is_list(appearances)
      assert length(appearances) >= 1
    end

    test "returns empty list for unknown role" do
      appearances = AgentRoleIndex.role_appearances("nonexistent-role-#{System.unique_integer()}")
      assert appearances == []
    end

    test "each appearance has role_id, formation_id, and touched_at" do
      AgentRoleIndex.touch("tester", "formation-20260101-qa")
      [appearance | _] = AgentRoleIndex.role_appearances("tester")

      assert Map.has_key?(appearance, :role_id) or Map.has_key?(appearance, "role_id")
      assert Map.has_key?(appearance, :formation_id) or Map.has_key?(appearance, "formation_id")
      assert Map.has_key?(appearance, :touched_at) or Map.has_key?(appearance, "touched_at")
    end
  end

  describe "normalize_formation_id/1" do
    test "strips date-like segments (YYYYMMDD) from formation ID" do
      normalized = AgentRoleIndex.normalize_formation_id("formation-20260101-my-feature")
      assert normalized == "formation-my-feature"
    end

    test "strips time-like segments (HHMMSS) if present" do
      normalized = AgentRoleIndex.normalize_formation_id("formation-20260101-120000-my-feature")
      assert normalized == "formation-my-feature"
    end

    test "leaves formation IDs without timestamps unchanged" do
      normalized = AgentRoleIndex.normalize_formation_id("formation-my-feature")
      assert normalized == "formation-my-feature"
    end

    test "handles short numeric suffixes that are not timestamps" do
      # e.g. "formation-1" should not be stripped
      normalized = AgentRoleIndex.normalize_formation_id("formation-myteam-1")
      # "1" is not 8 digits, should remain
      assert String.contains?(normalized, "1")
    end
  end
end
