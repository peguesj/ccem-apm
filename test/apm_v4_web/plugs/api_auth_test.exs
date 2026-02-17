defmodule ApmV4Web.Plugs.ApiAuthTest do
  use ExUnit.Case, async: false

  alias ApmV4Web.Plugs.ApiAuth

  defp build_conn(method, remote_ip, headers \\ []) do
    conn = Plug.Test.conn(method, "/api/status")

    headers
    |> Enum.reduce(%{conn | remote_ip: remote_ip}, fn {key, val}, acc ->
      Plug.Conn.put_req_header(acc, key, val)
    end)
  end

  describe "localhost bypass" do
    test "IPv4 localhost passes without auth" do
      conn = build_conn(:post, {127, 0, 0, 1})
      result = ApiAuth.call(conn, [])
      refute result.halted
    end

    test "IPv6 localhost passes without auth" do
      conn = build_conn(:post, {0, 0, 0, 0, 0, 0, 0, 1})
      result = ApiAuth.call(conn, [])
      refute result.halted
    end
  end

  describe "non-localhost requests" do
    test "POST without auth returns 401" do
      conn = build_conn(:post, {192, 168, 1, 100})
      result = ApiAuth.call(conn, [])
      assert result.halted
      assert result.status == 401
    end

    test "POST with valid bearer token passes" do
      {:ok, key} = ApmV4.ApiKeyStore.generate_key("auth-test")
      conn = build_conn(:post, {192, 168, 1, 100}, [{"authorization", "Bearer #{key}"}])
      result = ApiAuth.call(conn, [])
      refute result.halted
    end

    test "POST with invalid bearer token returns 401" do
      conn = build_conn(:post, {192, 168, 1, 100}, [{"authorization", "Bearer apm_invalid"}])
      result = ApiAuth.call(conn, [])
      assert result.halted
      assert result.status == 401
    end

    test "GET without auth passes by default (read bypass)" do
      conn = build_conn(:get, {192, 168, 1, 100})
      result = ApiAuth.call(conn, [])
      refute result.halted
    end
  end
end
