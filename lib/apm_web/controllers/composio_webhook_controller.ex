defmodule ApmWeb.ComposioWebhookController do
  @moduledoc """
  Thin controller wrapper for the Composio webhook handler.

  Delegates all body reading, HMAC validation, and PubSub broadcasting to
  `Apm.Plugins.Composio.ComposioWebhookHandler` (a Plug module).
  The route is intentionally outside the `:api` pipeline so the request body
  is not consumed before the HMAC check.
  """

  use ApmWeb, :controller

  alias Apm.Plugins.Composio.ComposioWebhookHandler

  @doc "POST /webhooks/composio"
  def receive(conn, _params) do
    ComposioWebhookHandler.call(conn, ComposioWebhookHandler.init([]))
  end
end
