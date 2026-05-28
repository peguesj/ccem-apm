defmodule ApmV5.Upm.FormationStateMachine do
  @moduledoc """
  Pure functional FSM for formation lifecycle states.

  Mirrors the `ApmV5.Auth.AgentLifecycle` pattern: typed atom states, an
  explicit transition map, pure `transition/2` function, and no GenServer.
  State is stored externally (ETS via `UpmStore`); this module only validates
  and advances transitions.

  ## Valid States

      :registered → :staged | :cancelled
      :staged     → :deployed | :cancelled
      :deployed   → :running | :failed | :cancelled
      :running    → :completing | :failed | :cancelled
      :completing → :completed | :failed
      :completed  (terminal)
      :failed     (terminal)
      :cancelled  (terminal)

  ## Usage

      iex> ApmV5.Upm.FormationStateMachine.transition(:registered, :staged)
      {:ok, :staged}

      iex> ApmV5.Upm.FormationStateMachine.transition(:completed, :running)
      {:error, :invalid_transition}

      iex> ApmV5.Upm.FormationStateMachine.parse("running")
      {:ok, :running}

      iex> ApmV5.Upm.FormationStateMachine.terminal?(:completed)
      true
  """

  @type state ::
          :registered
          | :staged
          | :deployed
          | :running
          | :completing
          | :completed
          | :failed
          | :cancelled

  @valid_transitions %{
    registered: [:staged, :cancelled],
    staged: [:deployed, :cancelled],
    deployed: [:running, :failed, :cancelled],
    running: [:completing, :failed, :cancelled],
    completing: [:completed, :failed],
    completed: [],
    failed: [],
    cancelled: []
  }

  @terminal_states [:completed, :failed, :cancelled]

  @valid_state_atoms Map.keys(@valid_transitions)

  @string_to_atom Map.new(@valid_state_atoms, fn s -> {Atom.to_string(s), s} end)

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Attempt a state transition.

  Returns `{:ok, new_state}` when the transition is valid, or
  `{:error, :invalid_transition}` when it is not.

  ## Examples

      iex> ApmV5.Upm.FormationStateMachine.transition(:registered, :staged)
      {:ok, :staged}

      iex> ApmV5.Upm.FormationStateMachine.transition(:completed, :running)
      {:error, :invalid_transition}

      iex> ApmV5.Upm.FormationStateMachine.transition(:running, :failed)
      {:ok, :failed}
  """
  @spec transition(state(), state()) :: {:ok, state()} | {:error, :invalid_transition}
  def transition(current_state, new_state)
      when is_atom(current_state) and is_atom(new_state) do
    allowed = Map.get(@valid_transitions, current_state, [])

    if new_state in allowed do
      {:ok, new_state}
    else
      {:error, :invalid_transition}
    end
  end

  @doc """
  Returns `true` when `state` is a terminal state (no further transitions).

  Terminal states: `:completed`, `:failed`, `:cancelled`.

  ## Examples

      iex> ApmV5.Upm.FormationStateMachine.terminal?(:completed)
      true

      iex> ApmV5.Upm.FormationStateMachine.terminal?(:running)
      false
  """
  @spec terminal?(state()) :: boolean()
  def terminal?(state), do: state in @terminal_states

  @doc """
  Return all valid state atoms in definition order.
  """
  @spec valid_states() :: [state()]
  def valid_states, do: @valid_state_atoms

  @doc """
  Parse a string or atom into a validated state atom.

  Returns `{:ok, atom}` when the input matches a known state,
  `{:error, :unknown_state}` otherwise.

  Accepts both string form (e.g. `"running"`) and atom form (e.g. `:running`).
  Intended for converting legacy string statuses from the API layer.

  ## Examples

      iex> ApmV5.Upm.FormationStateMachine.parse("running")
      {:ok, :running}

      iex> ApmV5.Upm.FormationStateMachine.parse(:staged)
      {:ok, :staged}

      iex> ApmV5.Upm.FormationStateMachine.parse("unknown")
      {:error, :unknown_state}
  """
  @spec parse(String.t() | atom()) :: {:ok, state()} | {:error, :unknown_state}
  def parse(value) when is_binary(value) do
    case Map.get(@string_to_atom, value) do
      nil -> {:error, :unknown_state}
      atom -> {:ok, atom}
    end
  end

  def parse(value) when is_atom(value) do
    if value in @valid_state_atoms do
      {:ok, value}
    else
      {:error, :unknown_state}
    end
  end

  def parse(_), do: {:error, :unknown_state}

  @doc """
  Returns the set of valid next states from `current_state`.
  """
  @spec next_states(state()) :: [state()]
  def next_states(state), do: Map.get(@valid_transitions, state, [])
end
