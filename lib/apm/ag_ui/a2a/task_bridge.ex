defmodule Apm.AgUi.A2A.TaskBridge do
  @moduledoc """
  Bridges AG-UI EventBus lifecycle events to A2A v0.3.0 task state transitions.

  ## Subscriptions

  - `"lifecycle:*"` via EventBus — catches `RUN_STARTED`, `RUN_FINISHED`,
    `RUN_ERROR`, and the approval gate's `"CUSTOM"` events.
  - `"apm:approvals"` via PubSub — catches `{:approval_requested, agent_id, gate_id}`
    messages emitted by the authorization pipeline.
  - EventBus `"CUSTOM"` events with `name == "approval_requested"` (emitted by
    `Apm.AgUi.ApprovalGate`) are also handled here.

  ## Lifecycle Mapping

  | AG-UI event type  | Task transition            |
  |-------------------|---------------------------|
  | `RUN_STARTED`     | `:submitted → :working`   |
  | `RUN_FINISHED`    | `:working  → :completed`  |
  | `RUN_ERROR`       | `:working  → :failed`     |
  | approval_required | `:working  → :input_required` |

  Tasks are looked up by `agent_id`.  If multiple tasks exist for an agent the
  most-recently-created non-terminal one is used.

  ## Auto-create behaviour

  On `RUN_STARTED` if no task exists for the agent, a new task is created with
  a synthetic envelope id derived from the event `run_id` (falling back to a
  generated value).  This ensures coverage even when `TaskStore.create_task/3`
  was not called explicitly.
  """

  use GenServer

  require Logger

  alias Apm.AgUi.A2A.TaskStore
  alias Apm.AgUi.EventBus

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start the TaskBridge supervisor child."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    EventBus.subscribe("lifecycle:*")
    EventBus.subscribe("CUSTOM")

    # Subscribe to PubSub for auth approval-required events
    Phoenix.PubSub.subscribe(Apm.PubSub, "apm:approvals")
    Phoenix.PubSub.subscribe(Apm.PubSub, "auth:pending")

    {:ok, %{}}
  end

  # -- EventBus lifecycle events ----------------------------------------------

  @impl true
  def handle_info({:event_bus, _topic, %{type: "RUN_STARTED", data: data}}, state) do
    agent_id = get_agent_id(data)

    if agent_id do
      envelope_id = get_in(data, [:run_id]) || get_in(data, ["run_id"]) || generate_id()

      case find_open_task(agent_id, :submitted) do
        nil ->
          {:ok, task} = TaskStore.create_task(agent_id, envelope_id)
          do_transition(task.id, :working, "RUN_STARTED auto-create+transition")

        task ->
          do_transition(task.id, :working, "RUN_STARTED")
      end
    end

    {:noreply, state}
  end

  def handle_info({:event_bus, _topic, %{type: "RUN_FINISHED", data: data}}, state) do
    agent_id = get_agent_id(data)

    if agent_id do
      case find_open_task(agent_id, :working) do
        nil ->
          Logger.debug("[A2A.TaskBridge] RUN_FINISHED but no :working task for #{agent_id}")

        task ->
          do_transition(task.id, :completed, "RUN_FINISHED")
      end
    end

    {:noreply, state}
  end

  def handle_info({:event_bus, _topic, %{type: "RUN_ERROR", data: data}}, state) do
    agent_id = get_agent_id(data)
    error_msg = get_in(data, [:message]) || get_in(data, ["message"]) || "unknown error"

    if agent_id do
      case find_open_task(agent_id, :working) do
        nil ->
          Logger.debug("[A2A.TaskBridge] RUN_ERROR but no :working task for #{agent_id}")

        task ->
          # Store error in metadata before transitioning
          update_task_metadata(task.id, %{error: error_msg})
          do_transition(task.id, :failed, "RUN_ERROR")
      end
    end

    {:noreply, state}
  end

  # -- CUSTOM events (approval_requested from ApprovalGate) ------------------

  def handle_info(
        {:event_bus, _topic, %{type: "CUSTOM", data: %{name: "approval_requested"} = data}},
        state
      ) do
    agent_id = get_agent_id(data)

    if agent_id do
      case find_open_task(agent_id, :working) do
        nil ->
          Logger.debug(
            "[A2A.TaskBridge] approval_requested but no :working task for #{agent_id}"
          )

        task ->
          do_transition(task.id, :input_required, "approval_requested")
      end
    end

    {:noreply, state}
  end

  def handle_info({:event_bus, _topic, _event}, state), do: {:noreply, state}

  # -- PubSub approval events ------------------------------------------------

  def handle_info({:approval_requested, agent_id, _gate_id}, state) do
    case find_open_task(agent_id, :working) do
      nil -> :ok
      task -> do_transition(task.id, :input_required, "PubSub approval_requested")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp find_open_task(agent_id, preferred_status) do
    tasks = TaskStore.list_tasks(agent_id)

    terminal = [:completed, :failed, :cancelled, :rejected]

    # Prefer task in preferred_status; fall back to any non-terminal
    Enum.find(tasks, fn t -> t.status == preferred_status end) ||
      Enum.find(tasks, fn t -> t.status not in terminal end)
  end

  defp do_transition(task_id, new_status, reason) do
    case TaskStore.transition(task_id, new_status) do
      {:ok, _task} ->
        Logger.debug("[A2A.TaskBridge] task=#{task_id} → #{new_status} (#{reason})")

      {:error, reason_err} ->
        Logger.debug(
          "[A2A.TaskBridge] transition failed task=#{task_id} → #{new_status}: #{reason_err} (#{reason})"
        )
    end
  end

  defp update_task_metadata(task_id, extra) do
    case TaskStore.get_task(task_id) do
      nil ->
        :ok

      task ->
        # TaskStore has no direct metadata-update API; use a transition to
        # a state that allows metadata carry-over.  We patch via replace.
        updated = %{task | metadata: Map.merge(task.metadata, extra)}
        :ets.insert(:a2a_tasks, {task_id, updated})
    end
  end

  defp get_agent_id(data) when is_map(data) do
    data[:agent_id] || data["agent_id"]
  end

  defp get_agent_id(_), do: nil

  defp generate_id do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  end
end
