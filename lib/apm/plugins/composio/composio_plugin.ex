defmodule Apm.Plugins.Composio.ComposioPlugin do
  @moduledoc """
  APM plugin for Composio — managed tool-execution and auth SaaS for AI agents.

  Exposes 8 actions covering toolkit catalog, tool execution, connected accounts,
  and MCP server management. Supervises ComposioToolStore, ComposioAccountStore,
  and ComposioMcpRegistry as plugin-owned GenServers.
  """

  @behaviour Apm.Plugins.PluginBehaviour

  alias Apm.Plugins.Composio.ComposioClient
  alias Apm.Plugins.Composio.ComposioMcpRegistry
  alias Apm.Plugins.Composio.ComposioAccountStore
  alias Apm.Plugins.Composio.ComposioToolStore

  require Logger

  @plugin_version "1.0.0"

  # ── Identity ───────────────────────────────────────────────────────────────

  @impl true
  @spec plugin_name() :: String.t()
  def plugin_name, do: "composio"

  @impl true
  @spec plugin_description() :: String.t()
  def plugin_description,
    do: "Composio managed tool-execution — 1000+ integrations via MCP and REST API"

  @impl true
  @spec plugin_version() :: String.t()
  def plugin_version, do: @plugin_version

  @impl true
  @spec plugin_scope() :: :ccem
  def plugin_scope, do: :ccem

  # ── Configuration ──────────────────────────────────────────────────────────

  @impl true
  @spec config_schema() :: map()
  def config_schema do
    %{
      api_key: "secret",
      webhook_secret: "secret",
      default_user_id: "string"
    }
  end

  @impl true
  @spec default_config() :: map()
  def default_config do
    %{api_key: "", webhook_secret: "", default_user_id: "default"}
  end

  # ── Endpoints ──────────────────────────────────────────────────────────────

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{
        action: "list_toolkits",
        description: "List available Composio toolkits",
        params: %{page: "integer (optional)", limit: "integer (optional)", search: "string (optional)"}
      },
      %{
        action: "list_tools",
        description: "List tools for a given toolkit slug",
        params: %{toolkit: "string (required)"}
      },
      %{
        action: "execute_tool",
        description: "Execute a Composio tool action via proxy",
        params: %{action: "string (required)", params: "map (required)", user_id: "string (required)"}
      },
      %{
        action: "list_connected_accounts",
        description: "List connected OAuth accounts for a user",
        params: %{user_id: "string (required)"}
      },
      %{
        action: "connect_account",
        description: "Initiate an OAuth account connection for a toolkit",
        params: %{toolkit: "string (required)", user_id: "string (required)"}
      },
      %{
        action: "list_mcp_servers",
        description: "List registered Composio MCP servers",
        params: %{}
      },
      %{
        action: "register_mcp_server",
        description: "Create and register a new Composio MCP server",
        params: %{name: "string (required)", toolkits: "list (required)"}
      },
      %{
        action: "get_mcp_url",
        description: "Get the MCP connection URL for a server and user",
        params: %{server_id: "string (required)", user_id: "string (required)"}
      }
    ]
  end

  # ── Action Dispatch ────────────────────────────────────────────────────────

  @impl true
  @spec handle_action(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}

  def handle_action("list_toolkits", params, _opts) do
    opts =
      []
      |> maybe_put(:page, params["page"])
      |> maybe_put(:limit, params["limit"])
      |> maybe_put(:search, params["search"])

    case ComposioClient.list_toolkits(opts) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_action("list_tools", %{"toolkit" => slug}, _opts) when is_binary(slug) do
    case ComposioClient.list_tools(slug) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_action("list_tools", _params, _opts) do
    {:error, {:missing_param, "toolkit"}}
  end

  def handle_action("execute_tool", %{"action" => action, "params" => tool_params, "user_id" => user_id}, _opts)
      when is_binary(action) and is_map(tool_params) and is_binary(user_id) do
    case ComposioClient.execute_tool(action, tool_params, user_id) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_action("execute_tool", _params, _opts) do
    {:error, {:missing_params, "action, params, user_id required"}}
  end

  def handle_action("list_connected_accounts", %{"user_id" => user_id}, _opts)
      when is_binary(user_id) do
    case ComposioClient.list_connected_accounts(user_id) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_action("list_connected_accounts", _params, _opts) do
    {:error, {:missing_param, "user_id"}}
  end

  def handle_action("connect_account", %{"toolkit" => slug, "user_id" => user_id}, _opts)
      when is_binary(slug) and is_binary(user_id) do
    case ComposioClient.connect_account(slug, user_id) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_action("connect_account", _params, _opts) do
    {:error, {:missing_params, "toolkit and user_id required"}}
  end

  def handle_action("list_mcp_servers", _params, _opts) do
    servers = safe_list_servers()
    {:ok, %{servers: servers, count: length(servers)}}
  end

  def handle_action("register_mcp_server", %{"name" => name, "toolkits" => toolkits}, _opts)
      when is_binary(name) and is_list(toolkits) do
    case ComposioClient.create_mcp_server(name, toolkits) do
      {:ok, %{"id" => server_id} = result} ->
        config = %{
          "name" => name,
          "toolkits" => toolkits,
          "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "mcp_url_template" => ComposioClient.get_mcp_url(server_id, "{user_id}")
        }

        safe_register_server(server_id, config)
        {:ok, result}

      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_action("register_mcp_server", _params, _opts) do
    {:error, {:missing_params, "name and toolkits required"}}
  end

  def handle_action("get_mcp_url", %{"server_id" => server_id, "user_id" => user_id}, _opts)
      when is_binary(server_id) and is_binary(user_id) do
    url = ComposioClient.get_mcp_url(server_id, user_id)
    {:ok, %{url: url, server_id: server_id, user_id: user_id}}
  end

  def handle_action("get_mcp_url", _params, _opts) do
    {:error, {:missing_params, "server_id and user_id required"}}
  end

  def handle_action(action, _params, _opts) do
    {:error, {:unknown_action, action}}
  end

  # ── Optional Callbacks ─────────────────────────────────────────────────────

  @impl true
  @spec supervisor_children() :: [Supervisor.child_spec()]
  def supervisor_children do
    [
      ComposioToolStore,
      ComposioAccountStore,
      ComposioMcpRegistry
    ]
  end

  @impl true
  @spec live_views() :: [{String.t(), module(), keyword()}]
  def live_views do
    [{"/plugins/composio", ApmWeb.ComposioLive, [as: :composio_live]}]
  end

  @impl true
  @spec nav_items() :: [{String.t(), String.t(), String.t() | nil}]
  def nav_items do
    [{"Composio", "/plugins/composio", "hero-cube-transparent"}]
  end

  @impl true
  @spec dashboard_widgets() :: [map()]
  def dashboard_widgets do
    [
      %{
        id: "composio_status",
        name: "Composio Status",
        category: :plugin,
        source_module: __MODULE__,
        refresh_interval: 60_000,
        min_width: 3,
        min_height: 2,
        config_schema: %{},
        plugin: "composio",
        version: @plugin_version,
        description: "Composio connectivity status and toolkit count"
      }
    ]
  end

  @impl true
  @spec plugin_live_module() :: module()
  def plugin_live_module, do: ApmWeb.ComposioLive

  @impl true
  @spec default_enabled?() :: boolean()
  def default_enabled?, do: true

  # ── Private Helpers ────────────────────────────────────────────────────────

  @spec maybe_put(keyword(), atom(), term()) :: keyword()
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @spec safe_list_servers() :: [map()]
  defp safe_list_servers do
    ComposioMcpRegistry.list_servers()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @spec safe_register_server(String.t(), map()) :: :ok
  defp safe_register_server(server_id, config) do
    ComposioMcpRegistry.register_server(server_id, config)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
