defmodule Apm.Plugins.Mirofish.MiroClient do
  @moduledoc """
  HTTP client for the Miro REST API v2.

  Uses Erlang `:httpc` (no external deps). Access token is read from, in order:

    1. `MIRO_ACCESS_TOKEN` environment variable
    2. `~/.config/mirofish/token` file (single-line, trimmed)

  Returns tagged tuples `{:ok, map}` | `{:error, reason}` from every public
  function. Handles 429 rate-limit responses by sleeping for `Retry-After`
  seconds (capped) and retrying once.

  See `references/miro-api.md` for the endpoint inventory.
  """

  require Logger

  @base_url "https://api.miro.com/v2"
  @token_file "~/.config/mirofish/token"
  @default_timeout 10_000
  @max_retry_wait_ms 10_000

  # ── Public API ──────────────────────────────────────────────────────────────

  @spec get_token() :: {:ok, String.t()} | {:error, :no_token}
  def get_token do
    case System.get_env("MIRO_ACCESS_TOKEN") do
      nil -> read_token_file()
      "" -> read_token_file()
      token -> {:ok, String.trim(token)}
    end
  end

  @spec list_boards(keyword()) :: {:ok, map()} | {:error, term()}
  def list_boards(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    query = Keyword.get(opts, :query)

    qs =
      [{"limit", limit}, {"offset", offset}] ++
        if(query, do: [{"query", query}], else: [])

    request(:get, "/boards" <> encode_query(qs), nil)
  end

  @spec get_board(String.t()) :: {:ok, map()} | {:error, term()}
  def get_board(board_id) when is_binary(board_id) do
    request(:get, "/boards/#{board_id}", nil)
  end

  @spec create_board(map()) :: {:ok, map()} | {:error, term()}
  def create_board(attrs) when is_map(attrs) do
    request(:post, "/boards", attrs)
  end

  @spec create_sticky(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_sticky(board_id, payload) when is_binary(board_id) and is_map(payload) do
    request(:post, "/boards/#{board_id}/sticky_notes", payload)
  end

  @spec create_frame(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_frame(board_id, payload) when is_binary(board_id) and is_map(payload) do
    request(:post, "/boards/#{board_id}/frames", payload)
  end

  @spec create_text(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_text(board_id, payload) when is_binary(board_id) and is_map(payload) do
    request(:post, "/boards/#{board_id}/texts", payload)
  end

  @spec list_items(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_items(board_id, opts \\ []) when is_binary(board_id) do
    limit = Keyword.get(opts, :limit, 50)
    request(:get, "/boards/#{board_id}/items?limit=#{limit}", nil)
  end

  @spec delete_item(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete_item(board_id, item_id)
      when is_binary(board_id) and is_binary(item_id) do
    request(:delete, "/boards/#{board_id}/items/#{item_id}", nil)
  end

  # ── Response Parser (exposed for testing) ───────────────────────────────────

  @doc """
  Parses a raw HTTP body (string or charlist) as JSON. Returns
  `{:ok, decoded_map}` on success, or `{:ok, %{raw: body}}` when the
  body is not valid JSON (e.g. 204 No Content responses).
  """
  @spec parse_response_body(binary() | charlist()) :: {:ok, map() | list()}
  def parse_response_body(body) do
    body_str = to_string(body)

    case body_str do
      "" ->
        {:ok, %{}}

      _ ->
        case Jason.decode(body_str) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:ok, %{raw: body_str}}
        end
    end
  end

  # ── Private HTTP plumbing ───────────────────────────────────────────────────

  defp request(method, path, body, attempt \\ 0) do
    with {:ok, token} <- get_token() do
      url = String.to_charlist(@base_url <> path)
      headers = build_headers(token)

      result =
        case method do
          :get ->
            :httpc.request(:get, {url, headers}, [{:timeout, @default_timeout}], [])

          :delete ->
            :httpc.request(:delete, {url, headers}, [{:timeout, @default_timeout}], [])

          :post ->
            encoded = Jason.encode!(body || %{})

            :httpc.request(
              :post,
              {url, headers, ~c"application/json", String.to_charlist(encoded)},
              [{:timeout, @default_timeout}],
              []
            )

          :patch ->
            encoded = Jason.encode!(body || %{})

            :httpc.request(
              :patch,
              {url, headers, ~c"application/json", String.to_charlist(encoded)},
              [{:timeout, @default_timeout}],
              []
            )
        end

      handle_response(result, method, path, body, attempt)
    end
  end

  defp handle_response({:ok, {{_, status, _}, _headers, resp_body}}, _method, _path, _body, _attempt)
       when status in 200..299 do
    parse_response_body(resp_body)
  end

  defp handle_response({:ok, {{_, 204, _}, _headers, _resp}}, _method, _path, _body, _attempt) do
    {:ok, %{deleted: true}}
  end

  defp handle_response({:ok, {{_, 429, _}, headers, _resp}}, method, path, body, attempt)
       when attempt < 1 do
    wait_ms = retry_after_ms(headers)
    Logger.warning("[MiroClient] 429 rate limit — retrying in #{wait_ms}ms")
    Process.sleep(wait_ms)
    request(method, path, body, attempt + 1)
  end

  defp handle_response({:ok, {{_, status, _}, _headers, resp_body}}, _method, _path, _body, _attempt) do
    {:error, %{status: status, body: to_string(resp_body)}}
  end

  defp handle_response({:error, reason}, _method, _path, _body, _attempt) do
    {:error, reason}
  end

  defp build_headers(token) do
    [
      {~c"Authorization", String.to_charlist("Bearer " <> token)},
      {~c"Accept", ~c"application/json"}
    ]
  end

  defp retry_after_ms(headers) do
    seconds =
      headers
      |> Enum.find_value(fn {k, v} ->
        if String.downcase(to_string(k)) == "retry-after" do
          case Integer.parse(to_string(v)) do
            {n, _} -> n
            _ -> nil
          end
        end
      end)
      |> Kernel.||(1)

    min(seconds * 1000, @max_retry_wait_ms)
  end

  defp encode_query(pairs) do
    case pairs do
      [] ->
        ""

      list ->
        "?" <>
          (list
           |> Enum.map(fn {k, v} -> "#{k}=#{URI.encode_www_form(to_string(v))}" end)
           |> Enum.join("&"))
    end
  end

  defp read_token_file do
    path = Path.expand(@token_file)

    case File.read(path) do
      {:ok, content} ->
        token = content |> String.split("\n", trim: true) |> List.first() |> to_string() |> String.trim()

        if token == "" do
          {:error, :no_token}
        else
          {:ok, token}
        end

      {:error, _} ->
        {:error, :no_token}
    end
  end
end
