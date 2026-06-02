defmodule Apm.Plugins.Composio.ComposioClient do
  @moduledoc """
  HTTP client for the Composio REST API (https://backend.composio.dev/api/v3).

  Uses Erlang's built-in `:httpc` — no external HTTP dependencies required.
  Authentication via `X-API-Key` header, sourced from application config:

      config :apm, :composio, api_key: "your_key"

  All public functions return `{:ok, result}` or `{:error, reason}`.

  ## Error reasons

  - `:composio_unreachable` — network failure or connection refused
  - `:unauthorized` — HTTP 401
  - `{:http_error, status}` — other 4xx responses
  - `{:server_error, status}` — 5xx responses
  """

  require Logger

  @base_url "https://backend.composio.dev/api/v3"

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc "List available toolkits. Accepts :page, :limit, :search opts."
  @spec list_toolkits(keyword()) :: {:ok, map()} | {:error, term()}
  def list_toolkits(opts \\ []) do
    params = opts_to_params(opts, [:page, :limit, :search])
    get("/toolkits", params)
  end

  @doc "List tools for a given toolkit slug. Accepts :page, :limit opts."
  @spec list_tools(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_tools(toolkit_slug, opts \\ []) when is_binary(toolkit_slug) do
    params = opts_to_params(opts, [:page, :limit]) |> Map.put("toolkit", toolkit_slug)
    get("/tools", params)
  end

  @doc "Execute a tool action via Composio proxy."
  @spec execute_tool(String.t(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute_tool(action_name, params, user_id, _opts \\ [])
      when is_binary(action_name) and is_map(params) and is_binary(user_id) do
    body = %{
      "action" => action_name,
      "input" => params,
      "entity_id" => user_id
    }

    post("/tools/execute/proxy", body)
  end

  @doc "List connected accounts for a user."
  @spec list_connected_accounts(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_connected_accounts(user_id, _opts \\ []) when is_binary(user_id) do
    get("/connected_accounts", %{"entity_id" => user_id})
  end

  @doc "Initiate account connection for a toolkit and user."
  @spec connect_account(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def connect_account(toolkit_slug, user_id, _opts \\ [])
      when is_binary(toolkit_slug) and is_binary(user_id) do
    body = %{"toolkitSlug" => toolkit_slug, "entity_id" => user_id}
    post("/connected_accounts/link", body)
  end

  @doc "List MCP servers registered in Composio."
  @spec list_mcp_servers(keyword()) :: {:ok, map()} | {:error, term()}
  def list_mcp_servers(_opts \\ []) do
    get("/mcp/servers", %{})
  end

  @doc "Create a new MCP server with given name and list of toolkit slugs."
  @spec create_mcp_server(String.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def create_mcp_server(name, toolkits, _opts \\ [])
      when is_binary(name) and is_list(toolkits) do
    body = %{"name" => name, "toolkits" => toolkits}
    post("/mcp/servers", body)
  end

  @doc "Build the MCP URL string for a given server and user."
  @spec get_mcp_url(String.t(), String.t()) :: String.t()
  def get_mcp_url(server_id, user_id) when is_binary(server_id) and is_binary(user_id) do
    "#{@base_url}/mcp/servers/#{server_id}/connect?entity_id=#{URI.encode(user_id)}"
  end

  @doc "Check whether Composio is reachable. Returns boolean."
  @spec reachable?(keyword()) :: boolean()
  def reachable?(_opts \\ []) do
    case list_toolkits(limit: 1) do
      {:ok, _} -> true
      _ -> false
    end
  end

  # ── Private: HTTP helpers ──────────────────────────────────────────────────

  @spec get(String.t(), map()) :: {:ok, map()} | {:error, term()}
  defp get(path, params) do
    url = build_url(path, params)
    headers = build_headers()

    :httpc.request(:get, {String.to_charlist(url), headers}, http_opts(), [])
    |> handle_response()
  rescue
    e ->
      Logger.warning("[ComposioClient] GET #{path} exception: #{inspect(e)}")
      {:error, :composio_unreachable}
  catch
    :exit, reason ->
      Logger.warning("[ComposioClient] GET #{path} exit: #{inspect(reason)}")
      {:error, :composio_unreachable}
  end

  @spec post(String.t(), map()) :: {:ok, map()} | {:error, term()}
  defp post(path, body) do
    url = build_url(path, %{})
    headers = build_headers()
    json_body = Jason.encode!(body)

    :httpc.request(
      :post,
      {String.to_charlist(url), headers, ~c"application/json", String.to_charlist(json_body)},
      http_opts(),
      []
    )
    |> handle_response()
  rescue
    e ->
      Logger.warning("[ComposioClient] POST #{path} exception: #{inspect(e)}")
      {:error, :composio_unreachable}
  catch
    :exit, reason ->
      Logger.warning("[ComposioClient] POST #{path} exit: #{inspect(reason)}")
      {:error, :composio_unreachable}
  end

  @spec handle_response(any()) :: {:ok, map()} | {:error, term()}
  defp handle_response({:ok, {{_, status, _}, _headers, body}}) when status in 200..299 do
    raw = IO.chardata_to_string(body)

    case Jason.decode(raw) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:ok, %{raw: raw}}
    end
  end

  defp handle_response({:ok, {{_, 401, _}, _headers, _body}}) do
    {:error, :unauthorized}
  end

  defp handle_response({:ok, {{_, status, _}, _headers, _body}}) when status in 400..499 do
    {:error, {:http_error, status}}
  end

  defp handle_response({:ok, {{_, status, _}, _headers, _body}}) when status in 500..599 do
    {:error, {:server_error, status}}
  end

  defp handle_response({:error, reason}) do
    Logger.warning("[ComposioClient] HTTP error: #{inspect(reason)}")
    {:error, :composio_unreachable}
  end

  defp handle_response(other) do
    Logger.warning("[ComposioClient] Unexpected response: #{inspect(other)}")
    {:error, :composio_unreachable}
  end

  @spec build_url(String.t(), map()) :: String.t()
  defp build_url(path, params) when map_size(params) == 0 do
    @base_url <> path
  end

  defp build_url(path, params) do
    query = URI.encode_query(params)
    "#{@base_url}#{path}?#{query}"
  end

  @spec build_headers() :: [{charlist(), charlist()}]
  defp build_headers do
    api_key = Application.get_env(:apm, :composio, [])[:api_key] || ""

    [
      {~c"X-API-Key", String.to_charlist(api_key)},
      {~c"Content-Type", ~c"application/json"},
      {~c"Accept", ~c"application/json"}
    ]
  end

  @spec http_opts() :: keyword()
  defp http_opts do
    [
      timeout: 15_000,
      connect_timeout: 5_000,
      ssl: [verify: :verify_none]
    ]
  end

  @spec opts_to_params(keyword(), [atom()]) :: map()
  defp opts_to_params(opts, allowed_keys) do
    Enum.reduce(allowed_keys, %{}, fn key, acc ->
      case Keyword.get(opts, key) do
        nil -> acc
        val -> Map.put(acc, to_string(key), to_string(val))
      end
    end)
  end
end
