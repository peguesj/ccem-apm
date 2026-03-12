defmodule ApmV5Web.V2.ApprovalController do
  @moduledoc """
  REST API for approval gate management.

  ## US-027 Acceptance Criteria (DoD):
  - POST /api/v2/approvals/request creates an approval gate
  - POST /api/v2/approvals/:id/approve approves
  - POST /api/v2/approvals/:id/reject rejects with reason
  - GET /api/v2/approvals lists with ?status=pending filter
  - GET /api/v2/approvals/:id returns single gate
  - mix compile --warnings-as-errors passes
  """

  use ApmV5Web, :controller

  alias ApmV5.AgUi.ApprovalGate

  def index(conn, params) do
    gates =
      case params["status"] do
        "pending" -> ApprovalGate.list_pending()
        _ -> ApprovalGate.list_all()
      end

    json(conn, %{approvals: gates})
  end

  def show(conn, %{"id" => id}) do
    case ApprovalGate.get(id) do
      nil -> conn |> put_status(404) |> json(%{error: "Approval gate not found"})
      gate -> json(conn, gate)
    end
  end

  def request(conn, params) do
    agent_id = params["agent_id"] || "unknown"

    case ApprovalGate.request_approval(agent_id, params) do
      {:ok, gate_id} ->
        conn |> put_status(201) |> json(%{gate_id: gate_id, status: "pending"})
    end
  end

  def approve(conn, %{"id" => id} = params) do
    approver = params["approver"] || %{}

    case ApprovalGate.approve(id, approver) do
      :ok -> json(conn, %{status: "approved"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Gate not found"})
      {:error, :not_pending} -> conn |> put_status(409) |> json(%{error: "Gate is not pending"})
    end
  end

  def reject(conn, %{"id" => id} = params) do
    reason = params["reason"] || "No reason provided"

    case ApprovalGate.reject(id, reason) do
      :ok -> json(conn, %{status: "rejected"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Gate not found"})
      {:error, :not_pending} -> conn |> put_status(409) |> json(%{error: "Gate is not pending"})
    end
  end
end
