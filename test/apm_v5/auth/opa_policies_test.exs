defmodule ApmV5.Auth.OpaPoliciesTest do
  @moduledoc """
  TDD tests for the Rego policy files in priv/policies/ (auth-v10.1-s2 / CP-292).

  All four policy files are tested against OpaClient.evaluate/3 using a
  Bypass mock for the OPA sidecar.  A live OPA integration test is tagged
  :opa_live and skipped by default.

  Run with: mix test --only opa_policies
  """

  use ExUnit.Case, async: false

  @moduletag :opa_policies

  alias ApmV5.Auth.OpaClient

  @policies_dir Path.join(:code.priv_dir(:apm_v5), "policies")

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
  # Policy file existence
  # ---------------------------------------------------------------------------

  describe "priv/policies/ — policy files exist" do
    test "time_of_day.rego exists" do
      assert File.exists?(Path.join(@policies_dir, "time_of_day.rego"))
    end

    test "environment.rego exists" do
      assert File.exists?(Path.join(@policies_dir, "environment.rego"))
    end

    test "path_pattern.rego exists" do
      assert File.exists?(Path.join(@policies_dir, "path_pattern.rego"))
    end

    test "formation_role.rego exists" do
      assert File.exists?(Path.join(@policies_dir, "formation_role.rego"))
    end

    test "each policy file contains correct OPA package declaration" do
      expected_packages = %{
        "time_of_day.rego" => "package apm.agentlock.time_of_day",
        "environment.rego" => "package apm.agentlock.environment",
        "path_pattern.rego" => "package apm.agentlock.path_pattern",
        "formation_role.rego" => "package apm.agentlock.formation_role"
      }

      Enum.each(expected_packages, fn {filename, expected_pkg} ->
        content = File.read!(Path.join(@policies_dir, filename))
        assert String.contains?(content, expected_pkg),
               "#{filename} missing package declaration: #{expected_pkg}"
      end)
    end

    test "each policy file contains 'default allow = false'" do
      ~w[time_of_day.rego environment.rego path_pattern.rego formation_role.rego]
      |> Enum.each(fn filename ->
        content = File.read!(Path.join(@policies_dir, filename))
        assert String.contains?(content, "default allow = false"),
               "#{filename} missing 'default allow = false'"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # OpaClient.evaluate/3 — mocked sidecar with each policy
  # ---------------------------------------------------------------------------

  describe "time_of_day policy via OpaClient (mocked)" do
    test "business hours → allow", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/data/apm/agentlock/time_of_day", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"result": true}))
      end)

      assert {:ok, true} =
               OpaClient.evaluate("apm/agentlock/time_of_day", "allow", %{
                 tool_name: "Bash",
                 hour: 14,
                 role: "agent"
               })
    end

    test "outside business hours → deny", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/data/apm/agentlock/time_of_day", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"result": false}))
      end)

      assert {:ok, false} =
               OpaClient.evaluate("apm/agentlock/time_of_day", "allow", %{
                 tool_name: "Bash",
                 hour: 3,
                 role: "agent"
               })
    end
  end

  describe "environment policy via OpaClient (mocked)" do
    test "production + non-privileged role → deny", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/data/apm/agentlock/environment", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"result": false}))
      end)

      assert {:ok, false} =
               OpaClient.evaluate("apm/agentlock/environment", "allow", %{
                 tool_name: "Bash",
                 environment: "production",
                 role: "agent"
               })
    end

    test "staging environment → allow", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/data/apm/agentlock/environment", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"result": true}))
      end)

      assert {:ok, true} =
               OpaClient.evaluate("apm/agentlock/environment", "allow", %{
                 tool_name: "Bash",
                 environment: "staging",
                 role: "agent"
               })
    end
  end

  describe "path_pattern policy via OpaClient (mocked)" do
    test "sensitive path → deny", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/data/apm/agentlock/path_pattern", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"result": false}))
      end)

      assert {:ok, false} =
               OpaClient.evaluate("apm/agentlock/path_pattern", "allow", %{
                 tool_name: "Write",
                 params: %{file_path: "/home/user/.env"},
                 role: "agent"
               })
    end

    test "safe project path → allow", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/data/apm/agentlock/path_pattern", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"result": true}))
      end)

      assert {:ok, true} =
               OpaClient.evaluate("apm/agentlock/path_pattern", "allow", %{
                 tool_name: "Write",
                 params: %{file_path: "/home/user/myproject/src/main.ex"},
                 role: "agent",
                 allowed_path_prefixes: ["/home/user/myproject"]
               })
    end
  end

  describe "formation_role policy via OpaClient (mocked)" do
    test "orchestrator using Bash → allow", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/data/apm/agentlock/formation_role", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"result": true}))
      end)

      assert {:ok, true} =
               OpaClient.evaluate("apm/agentlock/formation_role", "allow", %{
                 tool_name: "Bash",
                 formation_role: "orchestrator",
                 formation_id: "fmt-test"
               })
    end

    test "swarm_agent using Bash → deny", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/data/apm/agentlock/formation_role", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"result": false}))
      end)

      assert {:ok, false} =
               OpaClient.evaluate("apm/agentlock/formation_role", "allow", %{
                 tool_name: "Bash",
                 formation_role: "swarm_agent",
                 formation_id: "fmt-test"
               })
    end

    test "swarm_agent reading files → allow", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/data/apm/agentlock/formation_role", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"result": true}))
      end)

      assert {:ok, true} =
               OpaClient.evaluate("apm/agentlock/formation_role", "allow", %{
                 tool_name: "Read",
                 formation_role: "swarm_agent",
                 formation_id: "fmt-test"
               })
    end
  end

  # ---------------------------------------------------------------------------
  # Live OPA integration — skipped by default
  # ---------------------------------------------------------------------------

  @tag :opa_live
  @tag :skip
  test "live OPA: time_of_day policy evaluates with real OPA sidecar" do
    # Remove the @tag :skip to run against a live OPA sidecar at localhost:8181
    # Start OPA: opa run --server priv/policies/time_of_day.rego
    Application.put_env(:apm_v5, ApmV5.Auth.OpaClient, base_url: "http://localhost:8181")

    assert :ok = OpaClient.health()

    {:ok, result} =
      OpaClient.evaluate("apm/agentlock/time_of_day", "allow", %{
        tool_name: "Bash",
        hour: 10,
        role: "agent"
      })

    assert is_boolean(result)
  end
end
