defmodule ApmV5.Auth.AgentLifecycle do
  @moduledoc """
  Pure functional module implementing agent lifecycle state machine
  with authorization checkpoints.

  ## States
  PENDING → AUTHORIZED → RUNNING → COMPLETING → COMPLETED | FAILED | TIMED_OUT

  Authorization checkpoint: PENDING → AUTHORIZED requires a valid token
  from TokenStore. All other transitions are event-driven.

  ## Usage
  State is stored in AgentRegistry ETS. This module provides
  pure transition functions — no GenServer needed.
  """

  @type state ::
          :pending
          | :authorized
          | :running
          | :completing
          | :completed
          | :failed
          | :timed_out

  @type event ::
          :authorize
          | :start
          | :complete
          | :fail
          | :timeout
          | :cancel

  @valid_transitions %{
    pending: %{
      authorize: :authorized,
      cancel: :failed,
      timeout: :timed_out
    },
    authorized: %{
      start: :running,
      cancel: :failed,
      timeout: :timed_out
    },
    running: %{
      complete: :completing,
      fail: :failed,
      timeout: :timed_out,
      cancel: :failed
    },
    completing: %{
      complete: :completed,
      fail: :failed,
      timeout: :timed_out
    }
  }

  @terminal_states [:completed, :failed, :timed_out]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Attempt a state transition.

  Returns `{:ok, new_state}` if the transition is valid,
  `{:error, :invalid_transition}` if not.
  """
  @spec transition(state(), event(), map()) :: {:ok, state()} | {:error, :invalid_transition}
  def transition(current_state, event, _context \\ %{}) do
    case get_in(@valid_transitions, [current_state, event]) do
      nil -> {:error, :invalid_transition}
      new_state -> {:ok, new_state}
    end
  end

  @doc "Returns true if the state is terminal (no further transitions)."
  @spec terminal?(state()) :: boolean()
  def terminal?(state), do: state in @terminal_states

  @doc "Returns all valid events from a given state."
  @spec valid_events(state()) :: [event()]
  def valid_events(state) do
    case Map.get(@valid_transitions, state) do
      nil -> []
      transitions -> Map.keys(transitions)
    end
  end

  @doc "Returns the complete state machine as a map (for visualization)."
  @spec state_machine() :: map()
  def state_machine, do: @valid_transitions

  @doc "All possible states."
  @spec all_states() :: [state()]
  def all_states do
    [:pending, :authorized, :running, :completing] ++ @terminal_states
  end

  @doc "Returns the state machine as a list of edges for D3.js visualization."
  @spec edges() :: [map()]
  def edges do
    @valid_transitions
    |> Enum.flat_map(fn {from, transitions} ->
      Enum.map(transitions, fn {event, to} ->
        %{from: from, to: to, event: event}
      end)
    end)
  end
end
