defmodule ApmV5.Plugins.Memory.ClaudeMemBridgeTest do
  @moduledoc """
  Tests for ClaudeMemBridge GenServer.

  Uses a fixture SQLite DB at `priv/test_fixtures/claude_mem_test.db`
  with the same schema as `~/.claude-mem/claude-mem.db`.

  Run with: mix test test/apm_v5/plugins/memory/claude_mem_bridge_test.exs
  """

  use ExUnit.Case, async: false

  @moduletag :claude_mem_bridge

  alias ApmV5.Plugins.Memory.ClaudeMemBridge

  @fixture_db Path.expand("../../../../priv/test_fixtures/claude_mem_test.db", __DIR__)
  @missing_db "/tmp/nonexistent_claude_mem_#{System.unique_integer()}.db"

  setup do
    # Stop any existing registered instance before each test
    case Process.whereis(ClaudeMemBridge) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 1000)
    end

    :ok
  end

  # Helper: start bridge against fixture DB
  defp start_fixture_bridge do
    Application.put_env(:apm_v5, :claude_mem_db_path, @fixture_db)

    try do
      {:ok, pid} = GenServer.start_link(ClaudeMemBridge, [], name: ClaudeMemBridge)
      pid
    after
      Application.delete_env(:apm_v5, :claude_mem_db_path)
    end
  end

  # Helper: start bridge against missing DB
  defp start_missing_bridge do
    Application.put_env(:apm_v5, :claude_mem_db_path, @missing_db)

    try do
      {:ok, pid} = GenServer.start_link(ClaudeMemBridge, [], name: ClaudeMemBridge)
      pid
    after
      Application.delete_env(:apm_v5, :claude_mem_db_path)
    end
  end

  # ── health ────────────────────────────────────────────────────────────────

  describe "health/0" do
    test "returns :ok when DB is open" do
      pid = start_fixture_bridge()
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert :ok = ClaudeMemBridge.health()
    end

    test "returns db_unavailable when DB is missing" do
      pid = start_missing_bridge()
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert {:error, :db_unavailable} = ClaudeMemBridge.health()
    end
  end

  # ── stats ─────────────────────────────────────────────────────────────────

  describe "stats/0" do
    test "returns count and ts bounds" do
      pid = start_fixture_bridge()
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert {:ok, %{count: count, min_ts: min_ts, max_ts: max_ts}} =
               ClaudeMemBridge.stats()

      assert count == 3
      assert is_binary(min_ts)
      assert is_binary(max_ts)
    end

    test "returns db_unavailable when DB is missing" do
      pid = start_missing_bridge()
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert {:error, :db_unavailable} = ClaudeMemBridge.stats()
    end
  end

  # ── search ────────────────────────────────────────────────────────────────

  describe "search/2" do
    setup do
      pid = start_fixture_bridge()
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{pid: pid}
    end

    test "returns rows matching narrative" do
      assert {:ok, rows} = ClaudeMemBridge.search("phoenix")
      assert length(rows) >= 1
      assert Enum.all?(rows, &(&1.source == "claude_mem"))
    end

    test "returns rows matching facts" do
      assert {:ok, rows} = ClaudeMemBridge.search("ecto")
      assert length(rows) >= 1
    end

    test "returns empty list for no matches" do
      assert {:ok, rows} = ClaudeMemBridge.search("zzznotfound999")
      assert rows == []
    end

    test "respects limit option" do
      assert {:ok, rows} = ClaudeMemBridge.search("a", limit: 1)
      assert length(rows) <= 1
    end

    test "each row has required VIKI fields" do
      assert {:ok, [row | _]} = ClaudeMemBridge.search("phoenix")

      for key <- [:source, :id, :text, :title, :ts, :session_id, :concepts, :files] do
        assert Map.has_key?(row, key), "missing key #{key}"
      end

      assert is_list(row.concepts)
      assert is_list(row.files)
    end

    test "files merges files_read and files_modified" do
      # First fixture row has files_read=["lib/foo.ex"] files_modified=["lib/bar.ex"]
      assert {:ok, rows} = ClaudeMemBridge.search("phoenix liveview")
      row = Enum.find(rows, &String.contains?(String.downcase(&1.text), "phoenix liveview"))
      assert row, "expected a row about phoenix liveview"
      assert "lib/foo.ex" in row.files
      assert "lib/bar.ex" in row.files
    end
  end

  # ── session ───────────────────────────────────────────────────────────────

  describe "session/1" do
    setup do
      pid = start_fixture_bridge()
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{pid: pid}
    end

    test "returns observations for a known session ordered by prompt_number" do
      assert {:ok, rows} = ClaudeMemBridge.session("sess-abc")
      assert length(rows) == 2

      [r1, r2] = rows
      assert r1.session_id == "sess-abc"
      assert r2.session_id == "sess-abc"
      # Ordered by prompt_number ASC: first row is Phoenix LiveView Setup (prompt 1)
      assert String.contains?(r1.title, "Phoenix")
    end

    test "returns empty list for unknown session" do
      assert {:ok, rows} = ClaudeMemBridge.session("sess-nonexistent")
      assert rows == []
    end

    test "single-observation session returns one row" do
      assert {:ok, rows} = ClaudeMemBridge.session("sess-xyz")
      assert length(rows) == 1
      assert hd(rows).session_id == "sess-xyz"
    end

    test "rows have source set to claude_mem" do
      assert {:ok, rows} = ClaudeMemBridge.session("sess-abc")
      assert Enum.all?(rows, &(&1.source == "claude_mem"))
    end
  end

  # ── unavailable DB ────────────────────────────────────────────────────────

  describe "when DB does not exist" do
    setup do
      pid = start_missing_bridge()
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{pid: pid}
    end

    test "search returns db_unavailable" do
      assert {:error, :db_unavailable} = ClaudeMemBridge.search("anything")
    end

    test "session returns db_unavailable" do
      assert {:error, :db_unavailable} = ClaudeMemBridge.session("s1")
    end

    test "stats returns db_unavailable" do
      assert {:error, :db_unavailable} = ClaudeMemBridge.stats()
    end
  end
end
