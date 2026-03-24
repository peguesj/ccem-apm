defmodule ApmV5.Auth.TokenStore do
  @moduledoc """
  GenServer managing execution token lifecycle for AgentLock authorization.

  Tokens are single-use, time-limited, and operation-bound:
  - `atk_` prefix with 16 hex characters
  - SHA-256 parameter binding prevents replay with different params
  - Default 60-second TTL with automatic expiry sweep every 10s
  - Atomic validate-and-consume prevents race conditions

  ## ETS Table
  `:agentlock_tokens` — keyed by token_id, stores `%ExecutionToken{}`
  """

  use GenServer

  require Logger

  alias ApmV5.Auth.Types.ExecutionToken

  @table :agentlock_tokens
  @sweep_interval_ms 10_000
  @default_ttl_seconds 60

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Generate a new execution token for an authorized tool call.

  Returns `{:ok, token_id}` where token_id has `atk_` prefix.
  The params_hash binds the token to specific parameters (SHA-256).
  """
  @spec generate(String.t(), String.t(), String.t(), map()) :: {:ok, String.t()}
  def generate(agent_id, session_id, tool_name, params \\ %{}) do
    GenServer.call(__MODULE__, {:generate, agent_id, session_id, tool_name, params})
  end

  @doc """
  Validate and consume a token in a single atomic operation.

  Returns `{:ok, %ExecutionToken{}}` on success.
  Returns `{:error, reason}` on failure:
  - `:not_found` — token does not exist
  - `:expired` — token TTL exceeded
  - `:consumed` — token already used (replay attempt)
  - `:revoked` — token was revoked
  - `:tool_mismatch` — tool name doesn't match
  - `:params_mismatch` — parameter hash doesn't match
  """
  @spec validate_and_consume(String.t(), String.t(), map()) ::
          {:ok, ExecutionToken.t()} | {:error, atom()}
  def validate_and_consume(token_id, tool_name, params \\ %{}) do
    GenServer.call(__MODULE__, {:validate_and_consume, token_id, tool_name, params})
  end

  @doc "Revoke an active token."
  @spec revoke(String.t()) :: :ok | {:error, :not_found}
  def revoke(token_id) do
    GenServer.call(__MODULE__, {:revoke, token_id})
  end

  @doc "Get token details without consuming."
  @spec get(String.t()) :: ExecutionToken.t() | nil
  def get(token_id) do
    case :ets.lookup(@table, token_id) do
      [{^token_id, token}] -> token
      [] -> nil
    end
  end

  @doc "List all active (non-consumed, non-expired) tokens."
  @spec list_active() :: [ExecutionToken.t()]
  def list_active do
    now = DateTime.utc_now()

    :ets.tab2list(@table)
    |> Enum.map(fn {_id, token} -> token end)
    |> Enum.filter(&(&1.status == :active and DateTime.compare(&1.expires_at, now) == :gt))
  end

  @doc "Return token counts by status."
  @spec stats() :: map()
  def stats do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, token} -> token.status end)
    |> Enum.frequencies()
    |> Map.merge(%{active: 0, used: 0, expired: 0, revoked: 0}, fn _k, v1, _v2 -> v1 end)
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_sweep()
    Logger.info("[TokenStore] Started — ETS table #{@table}")
    {:ok, %{total_issued: 0, total_consumed: 0}}
  end

  @impl true
  def handle_call({:generate, agent_id, session_id, tool_name, params}, _from, state) do
    token_id = generate_token_id()
    params_hash = hash_params(params)
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, @default_ttl_seconds, :second)

    token = %ExecutionToken{
      token_id: token_id,
      agent_id: agent_id,
      session_id: session_id,
      tool_name: tool_name,
      params_hash: params_hash,
      status: :active,
      issued_at: now,
      expires_at: expires_at
    }

    :ets.insert(@table, {token_id, token})
    {:reply, {:ok, token_id}, %{state | total_issued: state.total_issued + 1}}
  end

  @impl true
  def handle_call({:validate_and_consume, token_id, tool_name, params}, _from, state) do
    case :ets.lookup(@table, token_id) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [{^token_id, token}] ->
        now = DateTime.utc_now()
        params_hash = hash_params(params)

        result =
          cond do
            token.status == :used ->
              {:error, :consumed}

            token.status == :revoked ->
              {:error, :revoked}

            DateTime.compare(token.expires_at, now) != :gt ->
              :ets.insert(@table, {token_id, %{token | status: :expired}})
              {:error, :expired}

            token.tool_name != tool_name ->
              {:error, :tool_mismatch}

            token.params_hash != params_hash ->
              {:error, :params_mismatch}

            true ->
              consumed = %{token | status: :used, consumed_at: now}
              :ets.insert(@table, {token_id, consumed})
              {:ok, consumed}
          end

        new_state =
          case result do
            {:ok, _} -> %{state | total_consumed: state.total_consumed + 1}
            _ -> state
          end

        {:reply, result, new_state}
    end
  end

  @impl true
  def handle_call({:revoke, token_id}, _from, state) do
    case :ets.lookup(@table, token_id) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [{^token_id, token}] ->
        :ets.insert(@table, {token_id, %{token | status: :revoked}})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info(:sweep_expired, state) do
    now = DateTime.utc_now()
    expired_count = sweep_expired_tokens(now)

    if expired_count > 0 do
      Logger.debug("[TokenStore] Swept #{expired_count} expired tokens")
    end

    schedule_sweep()
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp generate_token_id do
    hex = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    "atk_#{hex}"
  end

  defp hash_params(params) when is_map(params) do
    params
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp hash_params(_), do: hash_params(%{})

  defp sweep_expired_tokens(now) do
    :ets.tab2list(@table)
    |> Enum.filter(fn {_id, token} ->
      token.status == :active and DateTime.compare(token.expires_at, now) != :gt
    end)
    |> Enum.each(fn {id, token} ->
      :ets.insert(@table, {id, %{token | status: :expired}})
    end)
    |> then(fn _ ->
      :ets.tab2list(@table)
      |> Enum.count(fn {_id, token} -> token.status == :expired end)
    end)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep_expired, @sweep_interval_ms)
  end
end
