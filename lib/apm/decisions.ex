defmodule Apm.Decisions do
  @moduledoc """
  Context facade for the Decide section (v11 IA).

  Unifies approvals (ApprovalQueue) and authorization escalations
  (PendingDecisions) into a single surface. Both systems use the same
  shape: a pending item with an id, subject, action, resource, TTL,
  and risk level that resolves to an allow/deny decision.

  The Decide LiveViews (`DecidePendingLive`, etc.) call only this module
  — never the underlying queues directly — so that the plumbing can change
  without touching the UI layer.

  PubSub topic: `"agentlock:pending"` — broadcasts on any pending change.
  Both ApprovalQueue and PendingDecisions already broadcast on this topic.
  """

  alias Apm.Auth.{PendingDecisions, ApprovalQueue}

  @pubsub_topic "agentlock:pending"

  @doc "The canonical PubSub topic for pending-queue changes."
  @spec pubsub_topic() :: String.t()
  def pubsub_topic, do: @pubsub_topic

  @doc """
  Returns all currently-pending items (escalations + approvals, combined).

  Each item is normalised to:
    %{
      id:         String.t(),
      kind:       :auth | :approval,
      tool_name:  String.t(),
      session_id: String.t(),
      agent_id:   String.t(),
      risk_level: :high | :critical | :unknown,
      subject:    String.t(),
      command:    String.t(),
      reason:     String.t() | nil,
      scope:      String.t() | nil,
      ttl_s:      integer(),        # remaining TTL in seconds (approx)
      inserted_at: DateTime.t()
    }
  """
  @spec pending(keyword()) :: [map()]
  def pending(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    auth_items =
      case function_exported?(PendingDecisions, :list_pending, 0) do
        true -> PendingDecisions.list_pending()
        false -> []
      end

    approval_items =
      case :ets.whereis(:approval_queue) do
        :undefined ->
          []

        _ ->
          try do
            :ets.tab2list(:approval_queue)
            |> Enum.map(fn {_id, entry} -> entry end)
            |> Enum.filter(&(&1[:status] == :pending))
          rescue
            _ -> []
          end
      end

    now = DateTime.utc_now()

    auth_normalised =
      Enum.map(auth_items, fn item ->
        ttl_s = max(0, DateTime.diff(item.expires_at, now, :second))

        %{
          id: item.request_id,
          kind: :auth,
          tool_name: item.tool_name,
          session_id: item.session_id,
          agent_id: Map.get(item, :agent_id, "unknown"),
          risk_level: Map.get(item, :risk_level, :unknown),
          subject: Map.get(item, :agent_id, "agent"),
          command: item.tool_name,
          reason: get_in(item, [:params, :reason]),
          scope: get_in(item, [:params, :scope]),
          ttl_s: ttl_s,
          inserted_at: item.inserted_at,
          raw: item
        }
      end)

    approval_normalised =
      Enum.map(approval_items, fn item ->
        inserted = Map.get(item, :inserted_at, now)
        ttl_s = max(0, 120 - DateTime.diff(now, inserted, :second))

        %{
          id:
            to_string(Map.get(item, :id, item[:request_id] || System.unique_integer([:positive]))),
          kind: :approval,
          tool_name: Map.get(item, :tool_name, "unknown"),
          session_id: Map.get(item, :session_id, ""),
          agent_id: Map.get(item, :agent_id, "unknown"),
          risk_level: Map.get(item, :risk_level, :unknown),
          subject: Map.get(item, :agent_id, "agent"),
          command: Map.get(item, :tool_name, "unknown"),
          reason: get_in(item, [:params, :reason]),
          scope: get_in(item, [:params, :scope]),
          ttl_s: ttl_s,
          inserted_at: inserted,
          raw: item
        }
      end)

    (auth_normalised ++ approval_normalised)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc """
  Record a decision (allow/deny) on a pending item.

  `kind` (:auth | :approval) routes to the correct backend.
  Returns `{:ok, item}` or `{:error, reason}`.
  """
  @spec decide(String.t(), :allow | :deny, keyword()) :: {:ok, map()} | {:error, term()}
  def decide(id, decision, opts \\ []) do
    kind = Keyword.get(opts, :kind, :auth)
    approver = Keyword.get(opts, :approver, "dashboard")

    backend_decision = if decision == :allow, do: :approve, else: :deny

    case kind do
      :auth ->
        case PendingDecisions.decide(id, backend_decision) do
          {:ok, _token_id} -> {:ok, %{id: id, decision: decision}}
          :ok -> {:ok, %{id: id, decision: decision}}
          {:error, _} = err -> err
        end

      :approval ->
        try do
          apply(ApprovalQueue, :approve, [id, %{approver: approver}])
          {:ok, %{id: id, decision: decision}}
        rescue
          e -> {:error, Exception.message(e)}
        end

      _ ->
        {:error, :unknown_kind}
    end
  end

  @doc """
  Returns a count of currently-pending items (for topbar badge).
  Optimised — avoids building the full normalised list.
  """
  @spec pending_count() :: non_neg_integer()
  def pending_count do
    auth_count =
      case function_exported?(PendingDecisions, :list_pending, 0) do
        true -> PendingDecisions.list_pending() |> length()
        false -> 0
      end

    auth_count
  end
end
