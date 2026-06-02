defmodule ApmWeb.Plugs.OpenApiErrorRenderer do
  @moduledoc """
  Error renderer for `OpenApiSpex.Plug.CastAndValidate`.

  Called when request validation fails for an annotated endpoint. Returns a
  structured JSON 422 response compatible with the CCEM API error envelope.

  Only reachable once controllers gain `@operation` annotations (Wave 2 /
  api-s5). In Wave 1 all paths are unannotated so this module is never invoked.

  Implements the `Plug` behaviour expected by `CastAndValidate`'s
  `:render_error` option: `init/1` receives the error list and `call/2`
  renders the response.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(errors), do: errors

  @impl Plug
  def call(conn, errors) when is_list(errors) do
    messages = Enum.map(errors, &OpenApiSpex.Cast.Error.message/1)

    body =
      Jason.encode!(%{
        ok: false,
        error: "request_validation_failed",
        messages: messages
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(422, body)
    |> halt()
  end

  def call(conn, error), do: call(conn, [error])
end
