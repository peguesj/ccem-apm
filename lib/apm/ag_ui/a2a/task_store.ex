defmodule Apm.AgUi.A2A.TaskStore do
  @moduledoc """
  A2A v0.3.0 task lifecycle state machine backed by ETS.

  Implements the A2A protocol task lifecycle with valid state transitions,
  PubSub broadcast on every transition, and a clean functional API.

  ## Task struct

      %{
        id:          String.t(),
        agent_id:    String.t(),
        status:      :submitted | :working | :input_required |
                     :completed | :failed | :cancelled | :rejected,
        created_at:  DateTime.t(),
        updated_at:  DateTime.t(),
        envelope_ids: [String.t()],
        metadata:    map()
      }

  ## State Transitions

      :submitted      -> [:working, :cancelled, :rejected]
      :working        -> [:input_required, :completed, :failed, :cancelled]
      :input_required -> [:working, :cancelled]
      :completed      -> []   (terminal)
      :failed         -> []   (terminal)
      :cancelled      -> []   (terminal)
      :rejected       -> []   (terminal)

  ## PubSub

  Every successful transition broadcasts
  `{:task_transition, task_id, from_status, to_status}` on `"a2a:tasks"`.
  """

  use GenServer

  require Logger

  @table :a2a_tasks

  @terminal_states [:completed, :failed, :cancelled, :rejected]

  @valid_transitions %{
    submitted: [:working, :cancelled, :rejected],
    working: [:input_required, :completed, :failed, :cancelled],
    input_required: [:working, :cancelled],
    completed: [],
    failed: [],
    cancelled: [],
    rejected: []
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start the TaskStore supervisor child."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Create a new task in `:submitted` state.

  `opts` may include:
  - `:metadata` — arbitrary map merged into task metadata
  """
  @spec create_task(String.t(), String.t(), keyword()) :: {:ok, map()}
  def create_task(agent_id, envelope_id, opts \\ []) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:create_task, agent_id, envelope_id, opts})
  end

  @doc """
  Transition `task_id` to `new_status`.

  Returns:
  - `{:ok, task}` on success
  - `{:error, :not_found}` if task_id does not exist
  - `{:error, :terminal_state}` if the current state is terminal
  - `{:error, :invalid_transition}` if the transition is not in the valid map
  """
  @spec transition(String.t(), atom()) ::
          {:ok, map()} | {:error, :invalid_transition | :terminal_state | :not_found}
  def transition(task_id, new_status) when is_binary(task_id) and is_atom(new_status) do
    GenServer.call(__MODULE__, {:transition, task_id, new_status})
  end

  @doc "Fetch a task by id.  Returns `nil` if not found."
  @spec get_task(String.t()) :: map() | nil
  def get_task(task_id) do
    case :ets.lookup(@table, task_id) do
      [{^task_id, task}] -> task
      [] -> nil
    end
  end

  @doc "List all tasks for `agent_id`."
  @spec list_tasks(String.t()) :: [map()]
  def list_tasks(agent_id) do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, task} -> task end)
    |> Enum.filter(fn task -> task.agent_id == agent_id end)
  end

  @doc "List all tasks with `status`."
  @spec list_by_status(atom()) :: [map()]
  def list_by_status(status) when is_atom(status) do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, task} -> task end)
    |> Enum.filter(fn task -> task.status == status end)
  end

  @doc "List all tasks (no filter)."
  @spec list_all() :: [map()]
  def list_all do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, task} -> task end)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:create_task, agent_id, envelope_id, opts}, _from, state) do
    now = DateTime.utc_now()

    task = %{
      id: generate_id(),
      agent_id: agent_id,
      status: :submitted,
      created_at: now,
      updated_at: now,
      envelope_ids: [envelope_id],
      metadata: Keyword.get(opts, :metadata, %{})
    }

    :ets.insert(@table, {task.id, task})

    Logger.debug("[A2A.TaskStore] created task=#{task.id} agent=#{agent_id} status=:submitted")
    {:reply, {:ok, task}, state}
  end

  def handle_call({:transition, task_id, new_status}, _from, state) do
    result = do_transition(task_id, new_status)
    {:reply, result, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_transition(task_id, new_status) do
    case :ets.lookup(@table, task_id) do
      [] ->
        {:error, :not_found}

      [{^task_id, task}] ->
        current = task.status

        cond do
          current in @terminal_states ->
            {:error, :terminal_state}

          new_status not in Map.get(@valid_transitions, current, []) ->
            {:error, :invalid_transition}

          true ->
            updated_task = %{task | status: new_status, updated_at: DateTime.utc_now()}
            :ets.insert(@table, {task_id, updated_task})

            Phoenix.PubSub.broadcast(
              Apm.PubSub,
              "a2a:tasks",
              {:task_transition, task_id, current, new_status}
            )

            Logger.debug(
              "[A2A.TaskStore] task=#{task_id} #{current} -> #{new_status}"
            )

            {:ok, updated_task}
        end
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
