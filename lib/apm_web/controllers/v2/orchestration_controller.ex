defmodule ApmWeb.V2.OrchestrationController do
  @moduledoc """
  REST API v2 controller for the orchestration system.

  Delegates to OrchestrationManager and OrchestrationRunStore.

  ## Endpoints

  - `GET  /api/v2/orchestrations`                      — list runs (optional ?type= filter)
  - `POST /api/v2/orchestrations`                      — start a new run
  - `GET  /api/v2/orchestrations/history`              — full run history from store
  - `GET  /api/v2/orchestrations/:id`                  — get single run
  - `DELETE /api/v2/orchestrations/:id`                — cancel a run
  - `POST /api/v2/orchestrations/:id/steps/:step_id/advance` — advance to step
  - `POST /api/v2/orchestrations/:id/replay`           — replay a historical run
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmWeb.Plugs.OpenApiErrorRenderer

  alias Apm.Orchestration.OrchestrationManager
  alias Apm.Orchestration.OrchestrationRunStore

  # ── GET /api/v2/orchestrations ───────────────────────────────────────────────

  operation(:index,
    summary: "List",
    tags: ["Orchestration"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def index(conn, params) do
    runs =
      case Map.get(params, "type") do
        nil -> OrchestrationManager.list_runs()
        t -> OrchestrationRunStore.list_by_type(String.to_existing_atom(t))
      end

    json(conn, %{runs: runs, count: length(runs)})
  rescue
    ArgumentError ->
      conn
      |> put_status(400)
      |> json(%{error: "invalid orchestration_type"})
  end

  # ── POST /api/v2/orchestrations ──────────────────────────────────────────────

  operation(:create,
    summary: "Create",
    tags: ["Orchestration"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def create(conn, params) do
    atomized = atomize_type(params)

    case OrchestrationManager.start_run(atomized, []) do
      {:ok, run} ->
        conn
        |> put_status(201)
        |> json(%{run: run})

      {:error, {:cycle_detected, msg}} ->
        conn
        |> put_status(422)
        |> json(%{error: "cycle_detected", detail: msg})

      {:error, {:missing_required_param, param}} ->
        conn
        |> put_status(422)
        |> json(%{error: "missing_required_param", param: param})

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{error: inspect(reason)})
    end
  end

  # ── GET /api/v2/orchestrations/history ───────────────────────────────────────

  operation(:history,
    summary: "History",
    tags: ["Orchestration"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def history(conn, _params) do
    runs = OrchestrationRunStore.list()
    json(conn, %{runs: runs, count: length(runs)})
  end

  # ── GET /api/v2/orchestrations/:id ───────────────────────────────────────────

  operation(:show,
    summary: "Get one",
    tags: ["Orchestration"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def show(conn, %{"id" => id}) do
    case OrchestrationManager.get_run(id) do
      {:ok, run} -> json(conn, %{run: run})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not_found"})
    end
  end

  # ── DELETE /api/v2/orchestrations/:id ────────────────────────────────────────

  operation(:delete,
    summary: "Delete",
    tags: ["Orchestration"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def delete(conn, %{"id" => id}) do
    case OrchestrationManager.cancel_run(id) do
      :ok -> json(conn, %{status: "cancelled"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not_found"})
    end
  end

  # ── POST /api/v2/orchestrations/:id/steps/:step_id/advance ───────────────────

  operation(:advance_step,
    summary: "Advance step",
    tags: ["Orchestration"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def advance_step(conn, %{"id" => id, "step_id" => step_id}) do
    case OrchestrationManager.advance_step(id, step_id) do
      {:ok, run} -> json(conn, %{run: run})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not_found"})
    end
  end

  # ── POST /api/v2/orchestration/runs/:run_id/steps/:step_id/approve ───────────

  @doc """
  Manually grant approval for an `:approval`-type step.

  Body (optional): `{"approver_id": "...", "reason": "..."}`
  Returns the updated run on success.
  """
  operation(:approve_step,
    summary: "Approve step",
    tags: ["Orchestration"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def approve_step(conn, %{"run_id" => run_id, "step_id" => step_id} = params) do
    approver_info = Map.take(params, ["approver_id", "reason"])

    case OrchestrationManager.grant_approval(run_id, step_id, approver_info) do
      {:ok, run} ->
        json(conn, %{run: run, approved: true})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "run not found"})

      {:error, :step_not_found} ->
        conn |> put_status(404) |> json(%{error: "step not found"})

      {:error, :not_an_approval_step} ->
        conn |> put_status(422) |> json(%{error: "step is not of type :approval"})
    end
  end

  # ── POST /api/v2/orchestrations/:id/replay ───────────────────────────────────

  operation(:replay,
    summary: "Replay",
    tags: ["Orchestration"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def replay(conn, %{"id" => id}) do
    case OrchestrationRunStore.get(id) do
      {:ok, original_run} ->
        params = %{
          steps: original_run.steps,
          edges: original_run.edges,
          orchestration_type: original_run.orchestration_type,
          metadata: original_run.metadata
        }

        case OrchestrationManager.start_run(params, []) do
          {:ok, run} ->
            conn
            |> put_status(201)
            |> json(%{run: run, replayed_from: id})

          {:error, reason} ->
            conn
            |> put_status(422)
            |> json(%{error: inspect(reason)})
        end

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp atomize_type(%{"orchestration_type" => t} = params) when is_binary(t) do
    Map.put(params, :orchestration_type, String.to_existing_atom(t))
  rescue
    ArgumentError -> Map.delete(params, "orchestration_type")
  end

  defp atomize_type(params), do: params
end
