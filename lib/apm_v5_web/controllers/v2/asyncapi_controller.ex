defmodule ApmV5Web.V2.AsyncApiController do
  @moduledoc """
  Serves the AsyncAPI 3.0 document for CCEM APM PubSub event streams.

  ## Endpoint

      GET /api/v2/asyncapi.yaml

  Returns the hand-authored `priv/static/asyncapi.yaml` document which
  documents all 28+ Phoenix.PubSub topics used by CCEM APM v9.3.1.

  The document follows AsyncAPI 3.0 specification and can be consumed by
  AsyncAPI Studio, Microcks, or any AsyncAPI-compatible tooling.

  ## api-s9 / CP-268 / US-475
  """

  use ApmV5Web, :controller

  @asyncapi_path Path.join(:code.priv_dir(:apm_v5), "static/asyncapi.yaml")

  @doc "GET /api/v2/asyncapi.yaml — serve AsyncAPI 3.0 spec"
  def show(conn, _params) do
    case File.read(@asyncapi_path) do
      {:ok, content} ->
        conn
        |> put_resp_content_type("text/yaml")
        |> send_resp(200, content)

      {:error, reason} ->
        conn
        |> put_status(503)
        |> json(%{error: "asyncapi.yaml not available", reason: inspect(reason)})
    end
  end
end
