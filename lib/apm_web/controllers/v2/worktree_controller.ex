defmodule ApmWeb.V2.WorktreeController do
  @moduledoc """
  REST API controller for worktree lifecycle tracking.

  Endpoints under `/api/worktrees`:
    * `GET    /api/worktrees`               — list all (filter via `?project=foo`)
    * `POST   /api/worktrees/register`      — register a new worktree
    * `GET    /api/worktrees/:id`           — fetch one
    * `PATCH  /api/worktrees/:id`           — update metadata
    * `DELETE /api/worktrees/:id`           — prune

  Delegates to `Apm.WorktreeStore`.
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmWeb.Plugs.OpenApiErrorRenderer

  alias Apm.WorktreeStore

  @doc "GET /api/worktrees — list all worktrees (optional ?project=foo filter)"
  operation :index,
    summary: "List",
    tags: ["Worktrees"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def index(conn, params) do
    items =
      case Map.get(params, "project") do
        nil -> WorktreeStore.list()
        project -> WorktreeStore.list_by_project(project)
      end

    json(conn, %{data: items, count: length(items)})
  end

  @doc "POST /api/worktrees/register — register a new worktree"
  operation :register,
    summary: "Register",
    tags: ["Worktrees"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

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
  operation :show,
    summary: "Get one",
    tags: ["Worktrees"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

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
  operation :update,
    summary: "Update",
    tags: ["Worktrees"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

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
  operation :delete,
    summary: "Delete",
    tags: ["Worktrees"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

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
