defmodule ApmV4.BackgroundTasksStore do
  @moduledoc """
  GenServer tracking Claude Code background processes, tasks, and agents.
  Stores name, definition, invoking_process, project, status, pid, logs, runtime_seconds.
  """
  use GenServer

  @max_log_lines 500

  # --- Client API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def register_task(attrs) do
    GenServer.call(__MODULE__, {:register_task, attrs})
  end

  def update_task(id, attrs) do
    GenServer.call(__MODULE__, {:update_task, id, attrs})
  end

  def append_log(id, line) do
    GenServer.cast(__MODULE__, {:append_log, id, line})
  end

  def stop_task(id) do
    GenServer.cast(__MODULE__, {:stop_task, id})
  end

  def list_tasks(filter \\ %{}) do
    GenServer.call(__MODULE__, {:list_tasks, filter})
  end

  def get_task(id) do
    GenServer.call(__MODULE__, {:get_task, id})
  end

  def delete_task(id) do
    GenServer.cast(__MODULE__, {:delete_task, id})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    {:ok, %{tasks: %{}}}
  end

  @impl true
  def handle_call({:register_task, attrs}, _from, state) do
    id = Map.get(attrs, "id") || ApmV4.Correlation.generate()
    task = %{
      id: id,
      name: Map.get(attrs, "name", "unnamed"),
      definition: Map.get(attrs, "definition", ""),
      invoking_process: Map.get(attrs, "invoking_process", ""),
      project: Map.get(attrs, "project", ""),
      status: Map.get(attrs, "status", "running"),
      pid: Map.get(attrs, "pid"),
      logs: [],
      runtime_seconds: 0,
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
