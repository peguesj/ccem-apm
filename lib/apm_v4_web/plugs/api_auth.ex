defmodule ApmV4Web.Plugs.ApiAuth do
  @moduledoc """
  API authentication plug with localhost bypass.

  - Localhost requests (127.0.0.1 / ::1) skip auth entirely.
  - For non-localhost: requires valid `Authorization: Bearer <token>` header.
  - GET requests can optionally bypass auth when `api_auth.require_auth_for_reads` is false (default).
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if localhost?(conn) do
      conn
    else
      maybe_authenticate(conn)
    end
  end

  defp localhost?(%{remote_ip: {127, 0, 0, 1}}), do: true
  defp localhost?(%{remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}}), do: true
  defp localhost?(_), do: false

  defp maybe_authenticate(conn) do
    if read_request?(conn) && !require_auth_for_reads?() do
      conn
    else
      authenticate(conn)
    end
  end

  defp read_request?(%{method: "GET"}), do: true
  defp read_request?(_), do: false

  defp require_auth_for_reads? do
    config = ApmV4.ConfigLoader.get_config()
    get_in(config, ["api_auth", "require_auth_for_reads"]) == true
  end

  defp authenticate(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        if ApmV4.ApiKeyStore.valid_key?(token) do
          conn
        else
          unauthorized(conn)
        end

      _ ->
        unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{"error" => "unauthorized"}))
    |> halt()
  end
end
