defmodule Apm.Plugins.Composio.ComposioWebhookHandler do
  @moduledoc """
  Plug for `POST /webhooks/composio`.

  Validates the HMAC-SHA256 signature in the `X-Composio-Signature` header
  (skip if `COMPOSIO_WEBHOOK_SECRET` env var is unset). On success, parses
  the JSON body and broadcasts `{:composio_trigger, payload}` to the
  `"composio:triggers"` PubSub topic.

  Returns:
  - 200 on success
  - 400 on HMAC mismatch
  - 422 on invalid JSON
  """

  @behaviour Plug

  require Logger

  import Plug.Conn

  @pubsub_topic "composio:triggers"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, body, conn} <- read_body(conn),
         :ok <- verify_signature(conn, body),
         {:ok, payload} <- parse_json(body) do
      Phoenix.PubSub.broadcast(Apm.PubSub, @pubsub_topic, {:composio_trigger, payload})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{ok: true}))
    else
      {:error, :hmac_mismatch} ->
        Logger.warning("[ComposioWebhookHandler] HMAC signature mismatch")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "invalid signature"}))

      {:error, :invalid_json} ->
        Logger.warning("[ComposioWebhookHandler] Invalid JSON body")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(422, Jason.encode!(%{error: "invalid JSON body"}))

      {:error, reason} ->
        Logger.warning("[ComposioWebhookHandler] Unexpected error: #{inspect(reason)}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(422, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec verify_signature(Plug.Conn.t(), binary()) :: :ok | {:error, :hmac_mismatch}
  defp verify_signature(conn, body) do
    case System.get_env("COMPOSIO_WEBHOOK_SECRET") do
      nil ->
        Logger.warning("[ComposioWebhookHandler] COMPOSIO_WEBHOOK_SECRET not set, skipping HMAC validation")
        :ok

      "" ->
        Logger.warning("[ComposioWebhookHandler] COMPOSIO_WEBHOOK_SECRET is empty, skipping HMAC validation")
        :ok

      secret ->
        expected = "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))
        received = get_req_header(conn, "x-composio-signature") |> List.first("") |> String.trim()

        if Plug.Crypto.secure_compare(expected, received) do
          :ok
        else
          {:error, :hmac_mismatch}
        end
    end
  end

  @spec parse_json(binary()) :: {:ok, map()} | {:error, :invalid_json}
  defp parse_json(body) do
    case Jason.decode(body) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, :invalid_json}
    end
  end
end
