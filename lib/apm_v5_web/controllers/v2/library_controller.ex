defmodule ApmV5Web.V2.LibraryController do
  @moduledoc """
  REST API controller for the CCEM Library catalog.

  Routes under /api/v2/library:
    GET /api/v2/library           -- full catalog summary with counts
    GET /api/v2/library/agents    -- all cataloged agents
    GET /api/v2/library/skills    -- all cataloged skills
    GET /api/v2/library/commands  -- all cataloged commands
    GET /api/v2/library/mcp       -- all MCP server configurations
    GET /api/v2/library/tools     -- all tools
    GET /api/v2/library/hooks     -- all hooks (filesystem + configured + user)
    GET /api/v2/library/patterns  -- all reusable patterns
    GET /api/v2/library/learnings -- all memory/learning files
    POST /api/v2/library/refresh  -- trigger a full rescan
  """

  use ApmV5Web, :controller

  alias ApmV5.LibraryStore

  @doc "GET /api/v2/library -- full catalog summary"
  def index(conn, _params) do
    summary = LibraryStore.summary()

    json(conn, %{
      data: summary,
      total: summary.agents + summary.skills + summary.mcp_servers +
             summary.tools + Map.get(summary, :hooks, 0) + summary.commands + summary.patterns + summary.learnings
    })
  end

  @doc "GET /api/v2/library/agents -- all agents"
  def agents(conn, _params) do
    items = LibraryStore.list_agents()
    json(conn, %{data: items, count: length(items)})
  end

  @doc "GET /api/v2/library/skills -- all skills"
  def skills(conn, _params) do
    items = LibraryStore.list_skills()
    json(conn, %{data: items, count: length(items)})
  end

  @doc "GET /api/v2/library/commands -- all commands"
  def commands(conn, _params) do
    items = LibraryStore.list_commands()
    json(conn, %{data: items, count: length(items)})
  end

  @doc "GET /api/v2/library/mcp -- all MCP servers"
  def mcp(conn, _params) do
    items = LibraryStore.list_mcp_servers()
    json(conn, %{data: items, count: length(items)})
  end

  @doc "GET /api/v2/library/tools -- all tools and hooks"
  def tools(conn, _params) do
    items = LibraryStore.list_tools()
    json(conn, %{data: items, count: length(items)})
  end

  @doc "GET /api/v2/library/hooks -- all hooks"
  def hooks(conn, _params) do
    items = LibraryStore.list_hooks()
    json(conn, %{data: items, count: length(items)})
  end

  @doc "GET /api/v2/library/patterns -- all reusable patterns"
  def patterns(conn, _params) do
    items = LibraryStore.list_patterns()
    json(conn, %{data: items, count: length(items)})
  end

  @doc "GET /api/v2/library/learnings -- all learnings"
  def learnings(conn, _params) do
    items = LibraryStore.list_learnings()
    json(conn, %{data: items, count: length(items)})
  end

  @doc "POST /api/v2/library/refresh -- trigger a rescan"
  def refresh(conn, _params) do
    LibraryStore.refresh()
    json(conn, %{status: "refresh_triggered"})
  end

  @doc """
  GET /api/v2/library/graph -- relationship graph for D3 rendering.

  Query params:
    * `focus` — focus node id (e.g. `skill:upm`)
    * `depth` — neighborhood radius (default 2)
    * `types` — comma-separated node types to include (e.g. `skill,agent`)
  """
  def graph(conn, params) do
    opts =
      []
      |> maybe_put(:focus, Map.get(params, "focus"))
      |> put_depth(Map.get(params, "depth"))
      |> put_types(Map.get(params, "types"))

    graph = ApmV5.Library.GraphBuilder.build_graph(opts)

    json(conn, %{data: graph, count: length(graph.nodes)})
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp put_depth(opts, nil), do: Keyword.put(opts, :depth, 2)
  defp put_depth(opts, value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> Keyword.put(opts, :depth, n)
      _ -> Keyword.put(opts, :depth, 2)
    end
  end
  defp put_depth(opts, value) when is_integer(value), do: Keyword.put(opts, :depth, value)

  defp put_types(opts, nil), do: opts
  defp put_types(opts, ""), do: opts
  defp put_types(opts, types) when is_binary(types) do
    parsed =
      types
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.map(&String.to_atom/1)

    case parsed do
      [] -> opts
      list -> Keyword.put(opts, :types, list)
    end
  end
end
