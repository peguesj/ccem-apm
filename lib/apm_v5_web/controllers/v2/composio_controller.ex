defmodule ApmV5Web.V2.ComposioController do
  @moduledoc """
  REST API for the Composio plugin (under /api/v2/composio).

  Routes:
    GET  /toolkits            — list available toolkits
    GET  /tools               — list tools for a toolkit (requires ?toolkit=slug)
    POST /tools/execute       — execute a tool action
    GET  /accounts            — list connected accounts (requires ?user_id=...)
    POST /accounts/connect    — initiate OAuth account connection
    GET  /mcp/servers         — list registered MCP servers
    POST /mcp/servers         — create a new MCP server

  Error codes:
    503 — Composio API unreachable
    401 — Composio API key unauthorized
    404 — resource not found
    502 — other upstream error
  """

  use ApmV5Web, :controller

  alias ApmV5.Plugins.Composio.ComposioClient

  # ── Toolkits ──────────────────────────────────────────────────────────────────

  def toolkits(conn, params) do
    opts =
      []
      |> maybe_put(:page, params["page"])
      |> maybe_put(:limit, params["limit"])
      |> maybe_put(:search, params["search"])

    case ComposioClient.list_toolkits(opts) do
      {:ok, result} -> json(conn, result)
      {:error, :composio_unreachable} -> conn |> put_status(503) |> json(%{error: "Composio API unreachable"})
      {:error, :unauthorized} -> conn |> put_status(401) |> json(%{error: "Invalid Composio API key"})
      {:error, {:http_error, status}} -> conn |> put_status(status_to_http(status)) |> json(%{error: "Composio error: #{status}"})
      {:error, {:server_error, _}} -> conn |> put_status(502) |> json(%{error: "Composio server error"})
      {:error, reason} -> conn |> put_status(502) |> json(%{error: inspect(reason)})
    end
  end

  # ── Tools ─────────────────────────────────────────────────────────────────────

  def tools(conn, %{"toolkit" => slug} = params) do
    opts =
      []
      |> maybe_put(:page, params["page"])
      |> maybe_put(:limit, params["limit"])

    case ComposioClient.list_tools(slug, opts) do
      {:ok, result} -> json(conn, result)
      {:error, :composio_unreachable} -> conn |> put_status(503) |> json(%{error: "Composio API unreachable"})
      {:error, :unauthorized} -> conn |> put_status(401) |> json(%{error: "Invalid Composio API key"})
      {:error, {:http_error, 404}} -> conn |> put_status(404) |> json(%{error: "toolkit not found: #{slug}"})
      {:error, {:http_error, status}} -> conn |> put_status(status_to_http(status)) |> json(%{error: "Composio error: #{status}"})
      {:error, reason} -> conn |> put_status(502) |> json(%{error: inspect(reason)})
    end
  end

  def tools(conn, _params) do
    conn |> put_status(400) |> json(%{error: "Missing required query param: toolkit"})
  end

  # ── Tool Execution ─────────────────────────────────────────────────────────────

  def execute_tool(conn, %{"action" => action, "params" => tool_params, "user_id" => user_id})
      when is_binary(action) and is_map(tool_params) and is_binary(user_id) do
    case ComposioClient.execute_tool(action, tool_params, user_id) do
      {:ok, result} -> json(conn, result)
      {:error, :composio_unreachable} -> conn |> put_status(503) |> json(%{error: "Composio API unreachable"})
      {:error, :unauthorized} -> conn |> put_status(401) |> json(%{error: "Invalid Composio API key"})
      {:error, {:http_error, 404}} -> conn |> put_status(404) |> json(%{error: "action not found: #{action}"})
      {:error, {:http_error, status}} -> conn |> put_status(status_to_http(status)) |> json(%{error: "Composio error: #{status}"})
      {:error, reason} -> conn |> put_status(502) |> json(%{error: inspect(reason)})
    end
  end

  def execute_tool(conn, _params) do
    conn |> put_status(400) |> json(%{error: "Required: action (string), params (map), user_id (string)"})
  end

  # ── Connected Accounts ─────────────────────────────────────────────────────────

  def accounts(conn, %{"user_id" => user_id}) when is_binary(user_id) do
    case ComposioClient.list_connected_accounts(user_id) do
      {:ok, result} -> json(conn, result)
      {:error, :composio_unreachable} -> conn |> put_status(503) |> json(%{error: "Composio API unreachable"})
      {:error, :unauthorized} -> conn |> put_status(401) |> json(%{error: "Invalid Composio API key"})
      {:error, {:http_error, status}} -> conn |> put_status(status_to_http(status)) |> json(%{error: "Composio error: #{status}"})
      {:error, reason} -> conn |> put_status(502) |> json(%{error: inspect(reason)})
    end
  end

  def accounts(conn, _params) do
    conn |> put_status(400) |> json(%{error: "Missing required query param: user_id"})
  end

  # ── Account Connection ─────────────────────────────────────────────────────────

  def connect_account(conn, %{"toolkit" => slug, "user_id" => user_id})
      when is_binary(slug) and is_binary(user_id) do
    case ComposioClient.connect_account(slug, user_id) do
      {:ok, result} -> conn |> put_status(201) |> json(result)
      {:error, :composio_unreachable} -> conn |> put_status(503) |> json(%{error: "Composio API unreachable"})
      {:error, :unauthorized} -> conn |> put_status(401) |> json(%{error: "Invalid Composio API key"})
      {:error, {:http_error, 404}} -> conn |> put_status(404) |> json(%{error: "toolkit not found: #{slug}"})
      {:error, {:http_error, status}} -> conn |> put_status(status_to_http(status)) |> json(%{error: "Composio error: #{status}"})
      {:error, reason} -> conn |> put_status(502) |> json(%{error: inspect(reason)})
    end
  end

  def connect_account(conn, _params) do
    conn |> put_status(400) |> json(%{error: "Required: toolkit (string), user_id (string)"})
  end

  # ── MCP Servers ───────────────────────────────────────────────────────────────

  def mcp_servers(conn, _params) do
    case ComposioClient.list_mcp_servers() do
      {:ok, result} -> json(conn, result)
      {:error, :composio_unreachable} -> conn |> put_status(503) |> json(%{error: "Composio API unreachable"})
      {:error, :unauthorized} -> conn |> put_status(401) |> json(%{error: "Invalid Composio API key"})
      {:error, reason} -> conn |> put_status(502) |> json(%{error: inspect(reason)})
    end
  end

  def create_mcp_server(conn, %{"name" => name, "toolkits" => toolkits})
      when is_binary(name) and is_list(toolkits) do
    case ComposioClient.create_mcp_server(name, toolkits) do
      {:ok, result} -> conn |> put_status(201) |> json(result)
      {:error, :composio_unreachable} -> conn |> put_status(503) |> json(%{error: "Composio API unreachable"})
      {:error, :unauthorized} -> conn |> put_status(401) |> json(%{error: "Invalid Composio API key"})
      {:error, {:http_error, status}} -> conn |> put_status(status_to_http(status)) |> json(%{error: "Composio error: #{status}"})
      {:error, reason} -> conn |> put_status(502) |> json(%{error: inspect(reason)})
    end
  end

  def create_mcp_server(conn, _params) do
    conn |> put_status(400) |> json(%{error: "Required: name (string), toolkits (list)"})
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  @spec maybe_put(keyword(), atom(), term()) :: keyword()
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @spec status_to_http(integer()) :: integer()
  defp status_to_http(404), do: 404
  defp status_to_http(status) when status in 400..499, do: status
  defp status_to_http(_), do: 502
end
