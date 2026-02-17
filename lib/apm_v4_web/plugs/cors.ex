defmodule ApmV4Web.Plugs.CORS do
  @moduledoc """
  Simple CORS plug that sets Access-Control-Allow-Origin: * on all API responses.
  Matches v3 behavior for cross-origin dashboard and tool access.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%{method: "OPTIONS"} = conn, _opts) do
    conn
    |> put_cors_headers()
    |> send_resp(204, "")
    |> halt()
  end

  def call(conn, _opts) do
    put_cors_headers(conn)
  end

  defp put_cors_headers(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type, authorization")
  end
end
