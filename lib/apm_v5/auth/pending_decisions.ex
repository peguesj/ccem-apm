defmodule ApmV5.Auth.PendingDecisions do
  @moduledoc """
  Stores escalated authorization requests awaiting human approval.

  When a tool call is escalated (risk too high for auto-permit), it's
  queued here with a 120-second TTL. The web UI shows pending requests
  with Approve / Deny / Always Allow / Always Deny actions. The hook
  may poll `GET /api/v2/auth/pending/:id?wait=30` to long-poll for a
  decision before timing out and applying fail-open.

  ETS table `:agentlock_pending` stores:
    `{request_id, pending_map}`
  where `pending_map` contains:
    - `:request_id` — unique ID
    - `:tool_name` — tool being requested
    - `:session_id` — session context
    - `:agent_id` — requesting agent
    - `:risk_level` — :high | :critical
    - `:params` — tool params (may be redacted)
    - `:status` — :pending | :approved | :denied
    - `:decision` — nil | :approve | :deny
    - `:decided_at` — nil | DateTime
    - `:inserted_at` — DateTime
    - `:expires_at` — DateTime (inserted_at + 120s)
  """

  use GenServer
  require Logger

  alias ApmV5.Auth.TokenStore

  @table :agentlock_pending
  @ttl_seconds 20
  @sweep_ms 3_000

  # ── Client API ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Queue a new pending escalation. Returns `{:ok, request_id}`."
  @spec add(String.t(), String.t(), atom(), String.t(), map()) :: {:ok, String.t()}
  def add(tool_name, session_id, risk_level, agent_id, params \\ %{}) do
    GenServer.call(__MODULE__, {:add, tool_name, session_id, risk_level, agent_id, params})
  end

  @doc "Record a decision on a pending request. Broadcasts result on PubSub.
  Returns `{:ok, token_id}` when approved and a token is issued, `:ok` otherwise."
  @spec decide(String.t(), :approve | :deny) :: {:ok, String.t()} | :ok | {:error, :not_found}
  def decide(request_id, decision) when decision in [:approve, :deny] do
    GenServer.call(__MODULE__, {:decide, request_id, decision})
  end

  @doc "List all currently pending (undecided, non-expired) requests."
  @spec list_pending() :: [map()]
  def list_pending do
    case :ets.info(@table) do
      :undefined -> []
      _ ->
        now = DateTime.utc_now()
        :ets.tab2list(@table)
        |> Enum.map(fn {_id, entry} -> entry end)
        |> Enum.filter(&(&1.status == :pending && DateTime.after?(&1.expires_at, now)))
        |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    end
  end

  @doc "Get a single pending entry (any status)."
  @spec get(String.t()) :: map() | nil
  def get(request_id) do
    case :ets.info(@table) do
      :undefined -> nil
      _ ->
        case :ets.lookup(@table, request_id) do
          [{^request_id, entry}] -> entry
          [] -> nil
        end
    end
  end

  @doc """
  Poll for a decision on `request_id`, blocking up to `timeout_ms`.
  Returns `{:decided, entry}` (full entry map) or `{:timeout, :pending}`.
  Used by long-poll HTTP endpoint. The entry includes `token_id` when approved.
  """
  @spec poll(String.t(), non_neg_integer()) :: {:decided, map()} | {:timeout, :pending}
  def poll(request_id, timeout_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll(request_id, deadline)
  end

  defp do_poll(request_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 ->
        {:timeout, :pending}

      true ->
        case get(request_id) do
          %{status: :pending} ->
            Process.sleep(min(500, remaining))
            do_poll(request_id, deadline)

          %{decision: decision} = entry when decision in [:approve, :deny] ->
            {:decided, entry}

          nil ->
            {:timeout, :pending}
        end
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:add, tool_name, session_id, risk_level, agent_id, params}, _from, state) do
    request_id = "pending-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
    now = DateTime.utc_now()

    entry = %{
      request_id: request_id,
      tool_name: tool_name,
      session_id: session_id,
      agent_id: agent_id,
      risk_level: risk_level,
      params: sanitize_params(params),
      status: :pending,
      decision: nil,
      decided_at: nil,
      inserted_at: now,
      expires_at: DateTime.add(now, @ttl_seconds, :second)
    }

    :ets.insert(@table, {request_id, entry})

    Phoenix.PubSub.broadcast(ApmV5.PubSub, "agentlock:pending", {:pending_decision_added, entry})
    Phoenix.PubSub.broadcast(ApmV5.PubSub, "agentlock:authorization", {:pending_decision_added, entry})

    # Fire immediate notification so CCEMHelper delivers macOS banner within 1-2s
    Task.start(fn -> notify_approval_required(entry) end)

    Logger.info("[PendingDecisions] Queued: #{request_id} — #{tool_name} (#{risk_level})")
    {:reply, {:ok, request_id}, state}
  end

  @impl true
  def handle_call({:decide, request_id, decision}, _from, state) do
    case :ets.lookup(@table, request_id) do
      [{^request_id, entry}] ->
        case decision do
          :approve ->
            case TokenStore.generate(entry.agent_id, entry.session_id, entry.tool_name, entry.params) do
              {:ok, token_id} ->
                updated = %{entry |
                  status: :approved,
                  decision: :approve,
                  decided_at: DateTime.utc_now(),
                  token_id: token_id
                }
                :ets.insert(@table, {request_id, updated})
                Phoenix.PubSub.broadcast(ApmV5.PubSub, "agentlock:pending", {:pending_decision_resolved, updated})
                Phoenix.PubSub.broadcast(ApmV5.PubSub, "agentlock:authorization", {:pending_decision_resolved, updated})
                Logger.info("[PendingDecisions] Approved + token issued: #{request_id} → #{token_id}")
                {:reply, {:ok, token_id}, state}

              _err ->
                updated = %{entry |
                  status: :approved,
                  decision: :approve,
                  decided_at: DateTime.utc_now()
                }
                :ets.insert(@table, {request_id, updated})
                Phoenix.PubSub.broadcast(ApmV5.PubSub, "agentlock:pending", {:pending_decision_resolved, updated})
                Phoenix.PubSub.broadcast(ApmV5.PubSub, "agentlock:authorization", {:pending_decision_resolved, updated})
                Logger.warning("[PendingDecisions] Approved but token generation failed: #{request_id}")
                {:reply, :ok, state}
            end

          :deny ->
            updated = %{entry |
              status: :denied,
              decision: :deny,
              decided_at: DateTime.utc_now()
            }
            :ets.insert(@table, {request_id, updated})
            Phoenix.PubSub.broadcast(ApmV5.PubSub, "agentlock:pending", {:pending_decision_resolved, updated})
            Phoenix.PubSub.broadcast(ApmV5.PubSub, "agentlock:authorization", {:pending_decision_resolved, updated})
            Logger.info("[PendingDecisions] Denied: #{request_id}")
            {:reply, :ok, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = DateTime.utc_now()

    expired =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_id, entry} ->
        entry.status == :pending && DateTime.before?(entry.expires_at, now)
      end)

    Enum.each(expired, fn {id, _} ->
      :ets.delete(@table, id)
      Logger.debug("[PendingDecisions] Expired: #{id}")
    end)

    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp sanitize_params(params) when is_map(params) do
    params
    |> Map.take(["command", "tool_name", "file_path", "pattern", "description"])
    |> Enum.into(%{})
  end

  defp sanitize_params(_), do: %{}

  defp notify_approval_required(entry) do
    payload = Jason.encode!(%{
      type: "warning",
      title: "AgentLock — Approval Required",
      message: "#{entry.tool_name} · #{entry.risk_level} risk · #{entry.agent_id}",
      category: "agentlock",
      actions: [
        %{
          label: "Approve",
          href: "http://localhost:3032/api/v2/auth/decide",
          method: "post",
          body: %{request_id: entry.request_id, decision: "approve"}
        },
        %{
          label: "Deny",
          href: "http://localhost:3032/api/v2/auth/decide",
          method: "post",
          body: %{request_id: entry.request_id, decision: "deny"}
        }
      ],
      metadata: %{
        request_id: entry.request_id,
        agent_id: entry.agent_id,
        tool_name: entry.tool_name,
        risk_level: entry.risk_level
      }
    })

    :httpc.request(
      :post,
      {~c"http://localhost:3032/api/notify", [], ~c"application/json", payload},
      [{:timeout, 3_000}],
      []
    )
    |> case do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("[PendingDecisions] Notify failed: #{inspect(reason)}")
    end
  end
end
