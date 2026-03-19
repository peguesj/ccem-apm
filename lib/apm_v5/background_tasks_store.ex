defmodule ApmV5.BackgroundTasksStore do
  @moduledoc """
  GenServer tracking Claude Code background processes, tasks, and agents.
  Stores agent_name, agent_definition, invoking_process, log_path, runtime_ms, status, pid, logs.
  Broadcasts `{:task_updated, task}` on "tasks:updated" PubSub topic on every update.
  """
  use GenServer

  @max_log_lines 500

  # --- Client API ---

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec register_task(map()) :: {:ok, map()}
  def register_task(attrs) do
    GenServer.call(__MODULE__, {:register_task, attrs})
  end

  @spec update_task(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_task(id, attrs) do
    GenServer.call(__MODULE__, {:update_task, id, attrs})
  end

  @spec append_log(String.t(), String.t()) :: :ok
  def append_log(id, line) do
    GenServer.cast(__MODULE__, {:append_log, id, line})
  end

  @spec stop_task(String.t()) :: :ok
  def stop_task(id) do
    GenServer.cast(__MODULE__, {:stop_task, id})
  end

  @spec list_tasks(map()) :: [map()]
  def list_tasks(filter \\ %{}) do
    GenServer.call(__MODULE__, {:list_tasks, filter})
  end

  @spec get_task(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_task(id) do
    GenServer.call(__MODULE__, {:get_task, id})
  end

  @spec delete_task(String.t()) :: :ok
  def delete_task(id) do
    GenServer.cast(__MODULE__, {:delete_task, id})
  end

  @doc "Returns the last `lines` lines from the task's log_path file, or [] if unset."
  @spec get_task_logs(String.t(), non_neg_integer()) :: {:ok, [String.t()]} | {:error, atom()}
  def get_task_logs(id, lines \\ 50) do
    case get_task(id) do
      {:ok, %{log_path: log_path}} when is_binary(log_path) and log_path != "" ->
        case File.read(log_path) do
          {:ok, content} ->
            tail = content |> String.split("\n") |> Enum.take(-lines)
            {:ok, tail}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, _task} ->
        {:ok, []}

      {:error, _} = err ->
        err
    end
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    {:ok, %{tasks: %{}}}
  end

  @impl true
  def handle_call({:register_task, attrs}, _from, state) do
    id = Map.get(attrs, "id") || ApmV5.Correlation.generate()

    task = %{
      id: id,
      name: Map.get(attrs, "name", "unnamed"),
      agent_name: Map.get(attrs, "agent_name", Map.get(attrs, "name", "")),
      agent_definition: Map.get(attrs, "agent_definition", Map.get(attrs, "definition", "")),
      invoking_process: Map.get(attrs, "invoking_process", ""),
      log_path: Map.get(attrs, "log_path"),
      runtime_ms: Map.get(attrs, "runtime_ms", 0),
      project: Map.get(attrs, "project", ""),
      status: Map.get(attrs, "status", "running"),
      pid: Map.get(attrs, "pid"),
      os_pid: Map.get(attrs, "os_pid"),
      logs: [],
      started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      completed_at: nil
    }

    new_state = put_in(state, [:tasks, id], task)
    {:reply, {:ok, task}, new_state}
  end

  def handle_call({:update_task, id, attrs}, _from, state) do
    case Map.get(state.tasks, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      task ->
        updated = Map.merge(task, atomize_keys(attrs))

        updated =
          if Map.get(attrs, "status") in ["completed", "failed", "stopped"] && is_nil(updated.completed_at) do
            Map.put(updated, :completed_at, DateTime.utc_now() |> DateTime.to_iso8601())
          else
            updated
          end

        new_state = put_in(state, [:tasks, id], updated)
        Phoenix.PubSub.broadcast(ApmV5.PubSub, "tasks:updated", {:task_updated, updated})
        {:reply, :ok, new_state}
    end
  end

  def handle_call({:list_tasks, filter}, _from, state) do
    tasks =
      state.tasks
      |> Map.values()
      |> maybe_filter_by(:status, Map.get(filter, :status))
      |> maybe_filter_by(:project, Map.get(filter, :project))
      |> Enum.sort_by(& &1.started_at, :desc)

    {:reply, tasks, state}
  end

  def handle_call({:get_task, id}, _from, state) do
    case Map.get(state.tasks, id) do
      nil -> {:reply, {:error, :not_found}, state}
      task -> {:reply, {:ok, task}, state}
    end
  end

  @impl true
  def handle_cast({:append_log, id, line}, state) do
    case Map.get(state.tasks, id) do
      nil ->
        {:noreply, state}

      task ->
        logs = task.logs ++ [line]
        logs = Enum.take(logs, -@max_log_lines)
        new_state = put_in(state, [:tasks, id, :logs], logs)
        {:noreply, new_state}
    end
  end

  def handle_cast({:stop_task, id}, state) do
    case Map.get(state.tasks, id) do
      nil ->
        {:noreply, state}

      task ->
        if task.pid do
          System.cmd("kill", ["-TERM", to_string(task.pid)], stderr_to_stdout: true)
        end
        updated = task |> Map.put(:status, "stopped") |> Map.put(:completed_at, DateTime.utc_now() |> DateTime.to_iso8601())
        new_state = put_in(state, [:tasks, id], updated)
        {:noreply, new_state}
    end
  end

  def handle_cast({:delete_task, id}, state) do
    new_state = update_in(state, [:tasks], &Map.delete(&1, id))
    {:noreply, new_state}
  end

  # --- Helpers ---

  defp maybe_filter_by(list, _key, nil), do: list
  defp maybe_filter_by(list, key, value), do: Enum.filter(list, &(to_string(Map.get(&1, key)) == to_string(value)))

  defp atomize_keys(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    _ -> Map.new(map, fn {k, v} -> {k, v} end)
  end
end
