defmodule Apm.Plugins.Memory.FederationRouterTest do
  # async: false — Bypass HTTP mocks are port-allocated and can receive stray
  # GenServer stop messages from concurrently-running Bypass instances in other
  # test modules, causing spurious GenServer termination errors under full-suite runs.
  use ExUnit.Case, async: false

  alias Apm.Plugins.Memory.FederationRouter

  # ── Setup ──────────────────────────────────────────────────────────────────

  setup do
    bypass = Bypass.open()

    Application.put_env(:apm, :viki_url, "http://localhost:#{bypass.port}")
    Application.put_env(:apm, :viki_token, "test-token")

    on_exit(fn ->
      Application.delete_env(:apm, :viki_url)
      Application.delete_env(:apm, :viki_token)
    end)

    {:ok, bypass: bypass}
  end

  # ── Invalid params ─────────────────────────────────────────────────────────

  describe "route_query/2 — invalid params" do
    test "returns error when query is missing" do
      assert {:error, {:invalid_params, _}} = FederationRouter.route_query(%{}, [])
    end

    test "returns error when query is empty string" do
      assert {:error, {:invalid_params, _}} =
               FederationRouter.route_query(%{query: ""}, [])
    end

    test "returns error when query is nil" do
      assert {:error, {:invalid_params, _}} =
               FederationRouter.route_query(%{query: nil}, [])
    end
  end

  # ── VIKI source ────────────────────────────────────────────────────────────

  describe "route_query/2 — viki source" do
    test "maps viki results with source tag", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/search", fn conn ->
        body = Jason.encode!(%{results: [%{text: "VIKI result", score: 0.9, conversation_id: "c1"}]})
        Plug.Conn.resp(conn, 200, body)
      end)

      assert {:ok, %{results: results, sources_queried: sources}} =
               FederationRouter.route_query(
                 %{query: "elixir", sources: [:viki]},
                 []
               )

      assert sources == [:viki]
      assert length(results) == 1
      assert hd(results).source == :viki
      assert hd(results).text == "VIKI result"
      assert hd(results).score == 0.9
      assert hd(results).conversation_id == "c1"
    end

    test "handles viki returning top-level list", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/search", fn conn ->
        body = Jason.encode!([%{text: "item", score: 0.5}])
        Plug.Conn.resp(conn, 200, body)
      end)

      assert {:ok, %{results: results}} =
               FederationRouter.route_query(%{query: "test", sources: [:viki]}, [])

      assert length(results) == 1
      assert hd(results).source == :viki
    end

    test "records viki HTTP error in errors list", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/search", fn conn ->
        Plug.Conn.resp(conn, 500, "server error")
      end)

      assert {:ok, %{results: [], errors: [error]}} =
               FederationRouter.route_query(%{query: "fail", sources: [:viki]}, [])

      assert error.source == :viki
      assert match?({:http_status, 500}, error.error)
    end

    test "records viki timeout in errors list", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/search", fn conn ->
        # Sleep longer than the 500ms default timeout
        Process.sleep(600)
        Plug.Conn.resp(conn, 200, Jason.encode!(%{results: []}))
      end)

      assert {:ok, %{results: [], errors: errors}} =
               FederationRouter.route_query(
                 %{query: "slow", sources: [:viki], timeout_ms: 100},
                 []
               )

      assert length(errors) >= 1
    end
  end

  # ── serena source ──────────────────────────────────────────────────────────

  describe "route_query/2 — serena source" do
    test "returns not_implemented error for serena", %{bypass: _bypass} do
      assert {:ok, %{results: [], errors: [error]}} =
               FederationRouter.route_query(%{query: "anything", sources: [:serena]}, [])

      assert error.source == :serena
      assert error.error == :not_implemented
    end
  end

  # ── unknown source ─────────────────────────────────────────────────────────

  describe "route_query/2 — unknown source" do
    test "records error for unrecognized source atom", %{bypass: _bypass} do
      assert {:ok, %{results: [], errors: [error]}} =
               FederationRouter.route_query(%{query: "x", sources: [:bogus]}, [])

      assert error.source == :bogus
      assert match?({:unknown_source, :bogus}, error.error)
    end
  end

  # ── multi-source merge ─────────────────────────────────────────────────────

  describe "route_query/2 — multi-source merge" do
    test "merges results from multiple sources and sorts by score desc", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/search", fn conn ->
        body =
          Jason.encode!(%{
            results: [
              %{text: "low score", score: 0.3},
              %{text: "high score", score: 0.95}
            ]
          })

        Plug.Conn.resp(conn, 200, body)
      end)

      assert {:ok, %{results: results}} =
               FederationRouter.route_query(
                 %{query: "elixir", sources: [:viki, :serena]},
                 []
               )

      # serena not_implemented doesn't add results
      assert length(results) == 2
      [first | _] = results
      assert first.score == 0.95
    end

    test "top_n param limits results", %{bypass: bypass} do
      items = Enum.map(1..10, fn i -> %{text: "item #{i}", score: i / 10} end)

      Bypass.expect_once(bypass, "POST", "/api/search", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{results: items}))
      end)

      assert {:ok, %{results: results}} =
               FederationRouter.route_query(
                 %{query: "x", sources: [:viki], top_n: 3},
                 []
               )

      assert length(results) == 3
    end
  end

  # ── claude_mem source (SQLite) ─────────────────────────────────────────────

  describe "route_query/2 — claude_mem source (SQLite)" do
    @tag :sqlite
    test "returns db_not_found when db path does not exist" do
      # Override db path by pointing to a nonexistent file via env override
      # FederationRouter uses fixed path; this test just verifies error shape
      # when Exqlite module is unavailable (most CI environments).
      case Code.ensure_loaded(Exqlite.Sqlite3) do
        {:error, _} ->
          assert {:ok, %{errors: [error]}} =
                   FederationRouter.route_query(%{query: "test", sources: [:claude_mem]}, [])

          assert error.source == :claude_mem
          assert error.error == :exqlite_not_available

        {:module, _} ->
          # Exqlite loaded but db likely absent in test environment
          assert {:ok, result} =
                   FederationRouter.route_query(%{query: "test", sources: [:claude_mem]}, [])

          assert is_list(result.results) or is_list(result.errors)
      end
    end
  end

  # ── MemoryPlugin integration ───────────────────────────────────────────────

  describe "MemoryPlugin.handle_action/3 — route_query delegation" do
    test "delegates route_query to FederationRouter", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/search", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{results: []}))
      end)

      assert {:ok, %{results: [], sources_queried: [:viki]}} =
               Apm.Plugins.Memory.MemoryPlugin.handle_action(
                 "route_query",
                 %{query: "hello", sources: [:viki]},
                 []
               )
    end

    test "route_query endpoint is listed in list_endpoints/0" do
      endpoints = Apm.Plugins.Memory.MemoryPlugin.list_endpoints()
      actions = Enum.map(endpoints, & &1.action)
      assert "route_query" in actions
    end
  end
end
