defmodule ApmV5Web.V2.OrchestrationController do
  @moduledoc """
  REST API controller for the Orchestration System.

  Provides CRUD + replay for orchestration runs under `/api/v2/orchestrations`.
  """

  use ApmV5Web, :controller

  alias ApmV5.Orchestration.OrchestrationManager
  alias ApmV5.Orchestration.OrchestrationRunStore

  @doc "GET /api/v2/orchestrations — list active + recent runs"
  def index(conn, _params) do
    active = OrchestrationManager.list_all_runs()
    recent = OrchestrationRunStore.list_runs(limit: 20)

    json(conn, %{
      active: Enum.map(active, &serialize_run/1),
      recent: Enum.map(recent, &serialize_run/1)
    })
  end

  @doc "POST /api/v2/orchestrations — start new run"
  def create(conn, %{"workflow_id" => workflow_id} = params) do
    run_params =
      params
      |> Map.drop(["workflow_id"])
      |> maybe_atomize_dry_run()

    case OrchestrationManager.start_run(workflow_id, run_params) do
      {:ok, run} ->
        conn
        |> put_status(:created)
        |> json(%{run: serialize_run(run)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "workflow_id is required"})
  end

  @doc "GET /api/v2/orchestrations/:id — get run detail"
  def show(conn, %{"id" => id}) do
    run = OrchestrationManager.get_run(id) || OrchestrationRunStore.get_run(id)

    case run do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Run not found"})

      run ->
        next = OrchestrationManager.next_steps(id)

        json(conn, %{
          run: serialize_run(run),
          next_steps: next
        })
    end
  end

  @doc "DELETE /api/v2/orchestrations/:id — cancel run"
  def delete(conn, %{"id" => id}) do
    case OrchestrationManager.cancel_run(id) do
      {:ok, run} ->
        json(conn, %{run: serialize_run(run)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  @doc "POST /api/v2/orchestrations/:id/steps/:step_id/advance — advance step"
  def advance_step(conn, %{"id" => run_id, "step_id" => step_id} = params) do
    result = Map.get(params, "result", %{})

    case OrchestrationManager.advance_step(run_id, step_id, result) do
      {:ok, run} ->
        json(conn, %{run: serialize_run(run)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  @doc "GET /api/v2/orchestrations/history — list historical runs"
  def history(conn, params) do
    opts =
      []
      |> maybe_add_opt(:workflow_id, Map.get(params, "workflow_id"))
      |> maybe_add_opt(:status, parse_status(Map.get(params, "status")))
      |> maybe_add_opt(:limit, parse_int(Map.get(params, "limit")))

    runs = OrchestrationRunStore.list_runs(opts)
    json(conn, %{runs: Enum.map(runs, &serialize_run/1), count: length(runs)})
  end

  @doc "POST /api/v2/orchestrations/:id/replay — replay historical run"
  def replay(conn, %{"id" => id} = params) do
    extra = Map.get(params, "params", %{})

    case OrchestrationRunStore.replay_run(id, extra) do
      {:ok, new_run} ->
        conn
        |> put_status(:created)
        |> json(%{run: serialize_run(new_run), replayed_from: id})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp serialize_run(run) when is_map(run) do
    steps =
      (run[:steps] || %{})
      |> Enum.map(fn {id, step} ->
        %{
          id: id,
          status: step.status,
          started_at: step[:started_at],
          completed_at: step[:completed_at],
          result: step[:result],
          payload: step[:payload]
        }
      end)

    %{
      id: run[:id],
      workflow_id: run[:workflow_id],
      status: run[:status],
      steps: steps,
      edges: run[:edges] || [],
      current_wave: run[:current_wave] || 0,
      params: run[:params] || %{},
      dry_run: run[:dry_run] || false,
      execution_order: run[:execution_order],
      created_at: run[:created_at],
      updated_at: run[:updated_at],
      archived_at: run[:archived_at]
    }
  end

  defp maybe_atomize_dry_run(params) do
    case Map.get(params, "dry_run") do
      true -> Map.put(params, :dry_run, true)
      "true" -> Map.put(params, :dry_run, true)
      _ -> params
    end
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: [{key, value} | opts]

  defp parse_status(nil), do: nil
  defp parse_status(s) when is_binary(s), do: String.to_existing_atom(s)
  defp parse_status(_), do: nil

  defp parse_int(nil), do: nil
  defp parse_int(s) when is_binary(s), do: String.to_integer(s)
  defp parse_int(i) when is_integer(i), do: i
  defp parse_int(_), do: nil
end
