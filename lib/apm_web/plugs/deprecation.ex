defmodule ApmWeb.Plugs.Deprecation do
  @moduledoc """
  RFC 8594 Deprecation plug for legacy `/api/*` (non-v2) routes.

  Emits two response headers on any request whose path starts with `/api/`
  but does **not** start with `/api/v2/`:

    Deprecation: true
    Sunset: 2027-01-01

  Routes under `/api/v2/*` are exempt — they are the current, supported API
  surface and must not carry deprecation signals.

  ## Usage

  Wire into the legacy `:api` pipeline in `router.ex`:

      pipeline :api do
        # … existing plugs …
        plug ApmWeb.Plugs.Deprecation
      end

  ## RFC compliance notes

  - `Deprecation: true` — a simple boolean flag indicating the resource is
    deprecated (see RFC 8594 §2).
  - `Sunset: 2027-01-01` — RFC 8594 §3 recommends an HTTP-date (RFC 7231)
    but the plain date form is widely accepted and human-readable. Full
    compliance would use `Thu, 01 Jan 2027 00:00:00 GMT`; the date-only
    form is used here for clarity as noted in the OpenAPI spec.

  ## api-s8 / CP-267 / US-474
  """

  @behaviour Plug

  @sunset_date "2027-01-01"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: path} = conn, _opts) do
    if legacy_api_path?(path) do
      conn
      |> Plug.Conn.put_resp_header("deprecation", "true")
      |> Plug.Conn.put_resp_header("sunset", @sunset_date)
    else
      conn
    end
  end

  # Returns true when path is under /api/ but NOT under /api/v2/
  @spec legacy_api_path?(String.t()) :: boolean()
  defp legacy_api_path?(path) do
    String.starts_with?(path, "/api/") and not String.starts_with?(path, "/api/v2/")
  end
end
