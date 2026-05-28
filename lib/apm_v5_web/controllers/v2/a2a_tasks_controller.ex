defmodule ApmV5Web.V2.A2ATasksController do
  @moduledoc """
  REST API for A2A v0.3.0 task lifecycle.

  ## Endpoints

  - `GET /api/v2/a2a/tasks/:task_id` — task detail
  - `GET /api/v2/a2a/tasks?agent_id=&status=` — list / filter
  """

  use ApmV5Web, :controller

  alias ApmV5.AgUi.A2A.TaskStore

  # ── GET /api/v2/a2a/tasks/:task_id ────────────────────────────────────────

  @doc "Return a single A2A task by id."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"task_id" => task_id}) do
    case TaskStore.get_task(task_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", task_id: task_id})

      task ->
        conn |> json(%{task: serialize(task)})
    end
  end

  # ── GET /api/v2/a2a/tasks ─────────────────────────────────────────────────

  @doc "List A2A tasks, optionally filtered by agent_id and/or status."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    tasks =
      cond do
        agent_id = params["agent_id"] ->
          TaskStore.list_tasks(agent_id)

        status_str = params["status"] ->
          case parse_status(status_str) do
            {:ok, status} -> TaskStore.list_by_status(status)
            :error -> []
          end

        true ->
          TaskStore.list_all()
      end

    conn |> json(%{tasks: Enum.map(tasks, &serialize/1), count: length(tasks)})
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp serialize(task) do
    %{
      id: task.id,
      agent_id: task.agent_id,
      status: task.status,
      created_at: DateTime.to_iso8601(task.created_at),
      updated_at: DateTime.to_iso8601(task.updated_at),
      envelope_ids: task.envelope_ids,
      metadata: task.metadata
    }
  end

  defp parse_status(str) do
    atom = String.to_existing_atom(str)

    valid = [:submitted, :working, :input_required, :completed, :failed, :cancelled, :rejected]

    if atom in valid do
      {:ok, atom}
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end
end
