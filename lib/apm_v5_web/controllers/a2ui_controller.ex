defmodule ApmV5Web.A2uiController do
  @moduledoc """
  A2UI declarative component rendering endpoint.

  GET /api/a2ui/components returns UI component specifications per the
  Google A2UI protocol. Supports content negotiation:
  - Accept: application/jsonl → JSONL stream (one JSON object per line)
  - Accept: application/json → single JSON array response
  - Default (no Accept header or other) → JSONL stream
  """

  use ApmV5Web, :controller

  alias ApmV5.A2ui.ComponentBuilder

  @doc """
  Returns A2UI component specifications.

  Content negotiation via Accept header:
  - application/jsonl (default): Each line is a JSON object (JSONL stream)
  - application/json: Single JSON array response
  """
  def components(conn, _params) do
    components = ComponentBuilder.build_all()

    accept = get_req_header(conn, "accept") |> List.first() || ""

    if String.contains?(accept, "application/json") and
         not String.contains?(accept, "application/jsonl") do
      # Single JSON response
      conn
      |> put_resp_content_type("application/json")
      |> json(%{components: components})
    else
      # JSONL stream (default)
      conn =
        conn
        |> put_resp_content_type("application/jsonl")
        |> send_chunked(200)

      Enum.reduce_while(components, conn, fn component, acc ->
        line = Jason.encode!(component) <> "\n"

        case chunk(acc, line) do
          {:ok, acc} -> {:cont, acc}
          {:error, _reason} -> {:halt, acc}
        end
      end)
    end
  end
end
