defmodule Apm.Governance.IncidentResponseEngine do
  @moduledoc """
  Circuit-breaker GenServer for the NIST AI RMF MANAGE function.

  Subscribes to `"auth:decisions"` (PolicyDecisionStore) and `"auth:risks"`
  (RiskScoreAggregator). When a session exceeds configured thresholds the
  engine opens a circuit, installs a temporary `always_deny` rule in
  PolicyRulesStore keyed on a session-scoped wildcard pattern, and schedules
  automatic re-closure after a configurable TTL (default 15 minutes).

  ## Circuit open triggers (ANY one sufficient)

    * `critical_command_rate > 0.05` for a session in the last 5 minutes
    * `denial_rate > 0.20` for a session in the last 5 minutes

  ## Circuit open actions

    1. Insert `always_deny` rule for `"__circuit::{session_id}::*"` in
       PolicyRulesStore (wildcard key, prevents further decisions for session).
    2. Record entry in `:active_circuits` ETS table with TTL, reason, and
       original trust level.
    3. Broadcast `{:circuit_open, session_id, circuit}` on `"governance:circuits"`.
    4. Schedule `{:close_circuit, session_id}` after TTL ms.

  ## Circuit close (auto or manual)

    1. Remove the temporary policy rule.
    2. Delete ETS entry from `:active_circuits`.
    3. Broadcast `{:circuit_close, session_id}` on `"governance:circuits"`.

  ## ETS layout

  Table `:active_circuits` (`:set`, `:protected`, `read_concurrency: true`):
    - Key: `session_id` (binary)
    - Value: `%{opened_at, ttl_seconds, reason, original_trust, rule_key}`

  ## Configuration

      config :apm, Apm.Governance.IncidentResponseEngine,
        default_ttl_seconds: 900,          # 15 minutes
        critical_rate_threshold: 0.05,
        denial_rate_threshold: 0.20,
        window_seconds: 300                # 5-minute look-back

  ## HTTP endpoints

    `GET  /api/v2/governance/circuit-breakers`                   — list active
    `POST /api/v2/governance/circuit-breakers/:session_id/close` — manual close

  ## ControlRegistry

  The `:incident_response_engine` control is declared in ControlRegistry
  with `status: :satisfied`, frameworks NIST AI RMF MG-1.1 + NIST CSF RESPOND.

  Spec: CP-234 / US-466 / Plane 9ce8d9d4 — v9.3.0 comp-mg1.
  """

  use GenServer
  require Logger

  alias Apm.Auth.{PolicyDecisionStore, PolicyRulesStore}

  @table :active_circuits
  @pubsub_decisions "auth:decisions"
  @pubsub_risks "auth:risks"
  @pubsub_circuits "governance:circuits"

  @default_ttl_seconds 900
  @critical_rate_threshold 0.05
  @denial_rate_threshold 0.20
  @window_seconds 300

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type circuit :: %{
          opened_at: DateTime.t(),
          ttl_seconds: pos_integer(),
          reason: :critical_command_rate | :denial_rate,
          original_trust: String.t() | nil,
          rule_key: String.t()
        }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns a list of all currently active circuit breaker entries as JSON-safe maps.
  """
  @spec list_active_circuits() :: [map()]
  def list_active_circuits do
    case :ets.info(@table) do
      :undefined ->
        []

      _ ->
        :ets.tab2list(@table)
        |> Enum.map(fn {session_id, circuit} ->
          %{
            session_id: session_id,
            opened_at: DateTime.to_iso8601(circuit.opened_at),
            ttl_seconds: circuit.ttl_seconds,
            reason: to_string(circuit.reason),
            rule_key: circuit.rule_key
          }
        end)
        |> Enum.sort_by(& &1.opened_at, :desc)
    end
  end

  @doc """
  Manually closes the circuit for a given session_id.

  Returns `:ok` if found and closed, `{:error, :not_found}` if no active circuit.
  """
  @spec close_circuit(String.t()) :: :ok | {:error, :not_found}
  def close_circuit(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:close_circuit_manual, session_id})
  end

  @doc """
  Returns whether a circuit is currently open for a session.
  """
  @spec circuit_open?(String.t()) :: boolean()
  def circuit_open?(session_id) when is_binary(session_id) do
    case :ets.info(@table) do
      :undefined -> false
      _ -> :ets.member(@table, session_id)
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, {:read_concurrency, true}])

    Phoenix.PubSub.subscribe(Apm.PubSub, @pubsub_decisions)
    Phoenix.PubSub.subscribe(Apm.PubSub, @pubsub_risks)

    # Fail-soft subscription to SLO engine PubSub
    try do
      Phoenix.PubSub.subscribe(Apm.PubSub, "apm:slo")
    rescue
      _ -> :ok
    end

    Logger.info(
      "[IncidentResponseEngine] Started — circuit breaker active " <>
        "(crit_threshold=#{@critical_rate_threshold} denial_threshold=#{@denial_rate_threshold})"
    )

    {:ok, %{}}
  end

  # Triggered by PolicyDecisionStore PubSub broadcast
  @impl true
  def handle_info({:policy_decision, record}, state) do
    evaluate_session(record.session_id)
    {:noreply, state}
  end

  # Triggered by RiskScoreAggregator PubSub broadcast
  @impl true
  def handle_info({:risk_aggregated, {:session, session_id}, aggregate}, state) do
    # Proactive check on aggregated risk — open if denial_rate threshold exceeded
    if aggregate.denial_rate > @denial_rate_threshold and not circuit_open?(session_id) do
      open_circuit(session_id, :denial_rate, nil)
    end

    {:noreply, state}
  end

  # Auto-close timer fires
  @impl true
  def handle_info({:close_circuit, session_id}, state) do
    do_close_circuit(session_id, :auto)
    {:noreply, state}
  end

  # Ignore unrecognised PubSub messages (formation-scoped risk aggregates, SLO events, etc.)
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:close_circuit_manual, session_id}, _from, state) do
    result =
      case :ets.lookup(@table, session_id) do
        [] ->
          {:error, :not_found}

        [{^session_id, _}] ->
          do_close_circuit(session_id, :manual)
          :ok
      end

    {:reply, result, state}
  end

  # ---------------------------------------------------------------------------
  # Private — circuit evaluation
  # ---------------------------------------------------------------------------

  defp evaluate_session(session_id) when is_binary(session_id) do
    if circuit_open?(session_id) do
      # Circuit already open — nothing to do
      :ok
    else
      since = DateTime.add(DateTime.utc_now(), -@window_seconds, :second)

      decisions =
        PolicyDecisionStore.query(%{session_id: session_id, since: since, limit: 1_000})

      total = length(decisions)

      if total > 0 do
        critical_count = Enum.count(decisions, &(&1.risk_level == :critical))
        denied_count = Enum.count(decisions, &(&1.outcome == :deny))

        critical_rate = critical_count / total
        denial_rate = denied_count / total

        cond do
          critical_rate > @critical_rate_threshold ->
            open_circuit(session_id, :critical_command_rate, nil)

          denial_rate > @denial_rate_threshold ->
            open_circuit(session_id, :denial_rate, nil)

          true ->
            :ok
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private — open / close
  # ---------------------------------------------------------------------------

  defp open_circuit(session_id, reason, original_trust) do
    ttl = @default_ttl_seconds
    rule_key = circuit_rule_key(session_id)

    circuit = %{
      opened_at: DateTime.utc_now(),
      ttl_seconds: ttl,
      reason: reason,
      original_trust: original_trust,
      rule_key: rule_key
    }

    :ets.insert(@table, {session_id, circuit})

    # Install always_deny rule in PolicyRulesStore
    # Using a session-scoped wildcard key that PolicyRulesStore can match
    PolicyRulesStore.add_rule(rule_key, :always_deny)

    # Schedule auto-close
    Process.send_after(self(), {:close_circuit, session_id}, ttl * 1_000)

    # Broadcast circuit open event
    Phoenix.PubSub.broadcast(
      Apm.PubSub,
      @pubsub_circuits,
      {:circuit_open, session_id, circuit}
    )

    Logger.warning(
      "[IncidentResponseEngine] Circuit OPENED for session=#{session_id} " <>
        "reason=#{reason} ttl=#{ttl}s rule_key=#{rule_key}"
    )

    :ok
  end

  defp do_close_circuit(session_id, mode) do
    case :ets.lookup(@table, session_id) do
      [] ->
        :ok

      [{^session_id, circuit}] ->
        # Remove the temporary deny rule
        PolicyRulesStore.remove_rule(circuit.rule_key)

        # Delete ETS entry
        :ets.delete(@table, session_id)

        # Broadcast circuit close event
        Phoenix.PubSub.broadcast(
          Apm.PubSub,
          @pubsub_circuits,
          {:circuit_close, session_id}
        )

        Logger.info(
          "[IncidentResponseEngine] Circuit CLOSED for session=#{session_id} mode=#{mode}"
        )

        :ok
    end
  end

  # Generates a session-scoped rule key used in PolicyRulesStore.
  # Uses a prefix that can be checked via exact lookup (the PolicyRulesStore
  # supports a literal "*" wildcard for any tool; we store the rule under a
  # session-namespaced key so circuits don't collide and can be removed cleanly).
  defp circuit_rule_key(session_id) do
    "__circuit::#{session_id}::*"
  end
end
