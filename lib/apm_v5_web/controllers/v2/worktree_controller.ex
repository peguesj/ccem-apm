defmodule ApmV5Web.V2.WorktreeController do
  @moduledoc """
  REST API controller for worktree lifecycle tracking.

  Endpoints under `/api/worktrees`:
    * `GET    /api/worktrees`               — list all (filter via `?project=foo`)
    * `POST   /api/worktrees/register`      — register a new worktree
    * `GET    /api/worktrees/:id`           — fetch one
    * `PATCH  /api/worktrees/:id`           — update metadata
    * `DELETE /api/worktrees/:id`           — prune

  Delegates to `ApmV5.WorktreeStore`.
  """

  use ApmV5Web, :controller

  alias ApmV5.WorktreeStore

  @doc "GET /api/worktrees — list all worktrees (optional ?project=foo filter)"
  def index(conn, params) do
    items =
      case Map.get(params, "project") do
        nil -> WorktreeStore.list()
        project -> WorktreeStore.list_by_project(project)
      end

    json(conn, %{data: items, count: length(items)})
  end

  @doc "POST /api/worktrees/register — register a new worktree"
  def register(conn, params) do
    case WorktreeStore.register(params) do
      {:ok, metadata} ->
        conn
        |> put_status(:created)
        |> json(%{data: metadata})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: to_string(reason), message: error_message(reason)}})
    end
  end

  @doc "GET /api/worktrees/:id — fetch a single worktree"
  def show(conn, %{"id" => id}) do
    case WorktreeStore.get(id) do
      {:ok, metadata} ->
        json(conn, %{data: metadata})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "worktree #{id} not found"}})
    end
  end

  @doc "PATCH /api/worktrees/:id — update worktree metadata"
  def update(conn, %{"id" => id} = params) do
    attrs = Map.drop(params, ["id"])

    case WorktreeStore.update(id, attrs) do
      {:ok, metadata} ->
        json(conn, %{data: metadata})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "worktree #{id} not found"}})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: to_string(reason), message: error_message(reason)}})
    end
  end

  @doc "DELETE /api/worktrees/:id — prune a worktree"
  def delete(conn, %{"id" => id}) do
    case WorktreeStore.prune(id) do
      :ok ->
        json(conn, %{data: %{worktree_id: id, status: "pruned"}})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "worktree #{id} not found"}})
    end
  end

  defp error_message(:missing_branch), do: "branch is required"
  defp error_message(:missing_path), do: "path is required"
  defp error_message(other), do: inspect(other)
end
