defmodule ApmV4Web.Plugs.CorrelationId do
  @moduledoc """
  Plug that assigns a correlation ID to each request.

  Reads `X-Correlation-ID` from request headers if provided by the client,
  otherwise generates a new one. Stores it in the process dictionary and
  adds it as a response header.
  """

  import Plug.Conn
  alias ApmV4.Correlation

  @behaviour Plug

  @header "x-correlation-id"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    correlation_id =
      case get_req_header(conn, @header) do
        [id | _] -> id
        [] -> Correlation.generate()
      end

    Correlation.put(correlation_id)

    conn
    |> assign(:correlation_id, correlation_id)
    |> put_resp_header(@header, correlation_id)
  end
end
