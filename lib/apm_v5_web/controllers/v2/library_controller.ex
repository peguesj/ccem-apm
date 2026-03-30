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
end
