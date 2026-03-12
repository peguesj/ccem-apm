defmodule ApmV5Web.UatController do
  use ApmV5Web, :controller

  def results(conn, _params) do
    results = ApmV5.UatRunner.get_results()
    json(conn, %{results: results})
  end

  def summary(conn, _params) do
    summary = ApmV5.UatRunner.get_summary()
    json(conn, summary)
  end

  def run(conn, params) do
    case Map.get(params, "category") do
      nil ->
        case ApmV5.UatRunner.run_all() do
          {:ok, run_id} -> json(conn, %{status: "started", run_id: run_id})
          {:error, :already_running} -> conn |> put_status(409) |> json(%{error: "already_running"})
        end
      category ->
        cat = String.to_existing_atom(category)
        case ApmV5.UatRunner.run_category(cat) do
          {:ok, run_id} -> json(conn, %{status: "started", run_id: run_id, category: category})
          {:error, :already_running} -> conn |> put_status(409) |> json(%{error: "already_running"})
        end
    end
  end

  def clear(conn, _params) do
    ApmV5.UatRunner.clear_results()
    send_resp(conn, 204, "")
  end
end
