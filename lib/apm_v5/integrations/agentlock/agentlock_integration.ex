defmodule ApmV5.Integrations.Agentlock.AgentlockIntegration do
  @moduledoc """
  AgentLock authorization pipeline integration.

  Bridges APM to the 3-layer authorization pipeline (PolicyEngine → TokenStore → RateLimiter).
  Exposes authorization, token inspection, session queries, and rate-limit checks.
  """

  @behaviour ApmV5.Integrations.IntegrationBehaviour

  alias ApmV5.Auth.AuthorizationGate

  # ── IntegrationBehaviour ─────────────────────────────────────────────────────

  @impl true
  @spec integration_name() :: String.t()
  def integration_name, do: "agentlock"

  @impl true
  @spec integration_description() :: String.t()
  def integration_description,
    do: "AgentLock authorization pipeline — 3-layer risk evaluation, token management, rate limiting, and audit trail."

  @impl true
  @spec integration_version() :: String.t()
  def integration_version, do: "7.0.0"

  @impl true
  @spec protocol() :: atom()
  def protocol, do: :custom

  @impl true
  @spec connect(map()) :: {:ok, term()} | {:error, term()}
  def connect(_config), do: {:ok, :supervised}

  @impl true
  @spec disconnect() :: :ok
  def disconnect, do: :ok

  @impl true
  @spec status() :: atom()
  def status do
    if Process.whereis(ApmV5.Auth.TokenStore), do: :connected, else: :disconnected
  end

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{
        action: "authorize",
        description: "Authorize a tool call for an agent/session",
        params: %{agent_id: "string", session_id: "string", tool_name: "string", role: "string (optional)"}
      },
      %{
        action: "summary",
        description: "Get authorization gate summary (tool registry, recent decisions)",
        params: %{}
      },
      %{
        action: "list_tools",
        description: "List all registered tool authorization policies",
        params: %{}
      },
      %{
        action: "record_execution",
        description: "Record the result of an authorized tool execution",
        params: %{token_id: "string", tool_name: "string"}
      }
    ]
  end

  @impl true
  @spec handle_event(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_event("authorize", %{"agent_id" => agent_id, "session_id" => session_id, "tool_name" => tool_name} = params, _opts) do
    role = Map.get(params, "role", "agent")
    extra = Map.drop(params, ["agent_id", "session_id", "tool_name", "role"])

    case AuthorizationGate.authorize(agent_id, session_id, tool_name, role, extra) do
      {:ok, token_id} -> {:ok, %{authorized: true, token_id: token_id}}
      {:error, :rate_limited} -> {:ok, %{authorized: false, reason: "rate_limited"}}
      {:error, reason} -> {:ok, %{authorized: false, reason: inspect(reason)}}
    end
  end

  def handle_event("authorize", _params, _opts) do
    {:error, {:missing_param, "agent_id, session_id, and tool_name are required"}}
  end

  def handle_event("summary", _params, _opts) do
    summary = AuthorizationGate.summary()
    {:ok, %{summary: summary}}
  end

  def handle_event("list_tools", _params, _opts) do
    tools = AuthorizationGate.list_tools()
    {:ok, %{tools: tools, count: length(tools)}}
  end

  def handle_event("record_execution", %{"token_id" => token_id, "tool_name" => tool_name} = params, _opts) do
    result = Map.get(params, "result", %{})
    AuthorizationGate.record_execution(token_id, tool_name, result)
    {:ok, %{status: "recorded", token_id: token_id}}
  end

  def handle_event("record_execution", _params, _opts) do
    {:error, {:missing_param, "token_id and tool_name are required"}}
  end

  def handle_event(action, _params, _opts) do
    {:error, {:unknown_action, action}}
  end

  @impl true
  @spec supervisor_children() :: [Supervisor.child_spec()]
  def supervisor_children, do: []
end
