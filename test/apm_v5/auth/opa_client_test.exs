defmodule ApmV5.Auth.OpaClientTest do
  @moduledoc """
  TDD tests for ApmV5.Auth.OpaClient (auth-v10.1-s1 / CP-291).

  Uses Bypass to mock the OPA sidecar — no live OPA required.

  Run with: mix test --only opa_client
  """

  use ExUnit.Case, async: false

  @moduletag :opa_client

  alias ApmV5.Auth.OpaClient

  # ---------------------------------------------------------------------------
  # Setup: override base_url to point at Bypass
  # ---------------------------------------------------------------------------

  setup do
    bypass = Bypass.open()
    url = "http://localhost:#{bypass.port}"
    Application.put_env(:apm_v5, ApmV5.Auth.OpaClient, base_url: url, timeout_ms: 2_000)

    on_exit(fn ->
      Application.delete_env(:apm_v5, ApmV5.Auth.OpaClient)
    end)

    {:ok, bypass: bypass}
  end

  # ---------------------------------------------------------------------------
  # evaluate/3 — happy path
  # ---------------------------------------------------------------------------

  describe "evaluate/3 — OPA returns boolean result" do
    test "returns {:ok, true} when OPA result is true", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/data/apm/agentlock/test_policy", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"result": true}))
      end)

      assert {:ok, true} =
               OpaClient.evaluate("apm/agentlock/test_policy", "allow", %{
                 tool_name: "Bash",
                 role: "agent"
               })
    end

    test "returns {:ok, false} when OPA result is false", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/data/apm/agentlock/test_policy", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"result": false}))
      end)

      assert {:ok, false} =
               OpaClient.evaluate("apm/agentlock/test_policy", "allow", %{
                 tool_name: "Bash",
                 role: "untrusted"
               })
    end

    test "default rule_key is 'allow' (2-arity form)", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/data/apm/agentlock/time_of_day", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"result": true}))
      end)

      # Call the 2-arity version (package_rule, input)
      assert {:ok, true} =
               OpaClient.evaluate("apm/agentlock/time_of_day", "allow", %{hour: 10})
    end
  end

  describe "evaluate/3 — undefined rule" do
    test "returns {:ok, false} when OPA returns empty object (undefined rule)", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/data/apm/agentlock/undefined_rule", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({}))
      end)

      assert {:ok, false} =
               OpaClient.evaluate("apm/agentlock/undefined_rule", "allow", %{})
    end
  end

  describe "evaluate/3 — nested result map" do
    test "returns {:ok, value} extracted from nested map by rule_key", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/data/apm/agentlock/nested", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"result": {"allow": true, "reason": "time_ok"}}))
      end)

      assert {:ok, true} =
               OpaClient.evaluate("apm/agentlock/nested", "allow", %{hour: 14})
    end

    test "returns {:ok, false} when rule_key missing from nested map", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/data/apm/agentlock/nested", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"result": {"other_key": true}}))
      end)

      assert {:ok, false} =
               OpaClient.evaluate("apm/agentlock/nested", "allow", %{})
    end
  end

  describe "evaluate/3 — error cases" do
    test "returns {:error, {:http_error, status}} on non-200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/data/apm/agentlock/bad_policy", fn conn ->
        Plug.Conn.resp(conn, 404, ~s({"code": "undefined_document"}))
      end)

      assert {:error, {:http_error, 404}} =
               OpaClient.evaluate("apm/agentlock/bad_policy", "allow", %{})
    end

    test "returns {:error, {:connection_error, _}} when sidecar is down", %{bypass: bypass} do
      # Close bypass to simulate connection refused
      Bypass.down(bypass)

      result = OpaClient.evaluate("apm/agentlock/any_policy", "allow", %{})
      assert match?({:error, {:connection_error, _}}, result)

      Bypass.up(bypass)
    end
  end

  # ---------------------------------------------------------------------------
  # health/0
  # ---------------------------------------------------------------------------

  describe "health/0" do
    test "returns :ok when OPA sidecar responds 200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/health", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({}))
      end)

      assert :ok = OpaClient.health()
    end

    test "returns {:error, {:http_error, 503}} when OPA is unhealthy", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/health", fn conn ->
        Plug.Conn.resp(conn, 503, ~s({"error": "bundling"}))
      end)

      assert {:error, {:http_error, 503}} = OpaClient.health()
    end

    test "returns {:error, {:connection_error, _}} when sidecar unreachable", %{bypass: bypass} do
      Bypass.down(bypass)
      result = OpaClient.health()
      assert match?({:error, {:connection_error, _}}, result)
      Bypass.up(bypass)
    end
  end

  # ---------------------------------------------------------------------------
  # Configuration
  # ---------------------------------------------------------------------------

  describe "base_url/0 and timeout_ms/0" do
    test "base_url/0 returns configured URL" do
      assert String.starts_with?(OpaClient.base_url(), "http://localhost:")
    end

    test "timeout_ms/0 returns configured timeout" do
      assert OpaClient.timeout_ms() == 2_000
    end

    test "base_url/0 defaults to standard OPA port when unconfigured" do
      Application.delete_env(:apm_v5, ApmV5.Auth.OpaClient)
      assert OpaClient.base_url() == "http://localhost:8181"
    end
  end
end
