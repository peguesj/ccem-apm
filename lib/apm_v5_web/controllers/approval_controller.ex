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

  ## open_api_spex annotations (api-s5 Wave 1 / CP-262)
  All 5 actions annotated: index, show, request, approve, reject.
  """

  use ApmV5Web, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s5 Wave 1: all 5 approval actions are annotated.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmV5Web.Plugs.OpenApiErrorRenderer

  alias ApmV5Web.Schemas
  alias ApmV5.AgUi.ApprovalGate

  operation :index,
    summary: "List approval gates",
    description: "Returns all approval gates, optionally filtered by status.",
    tags: ["Approvals"],
    parameters: [
      status: [
        in: :query,
        type: :string,
        required: false,
        description: "Filter by status (pending | approved | rejected | timeout)"
      ]
    ],
    responses: [
      ok: {"Approval list", "application/json", Schemas.ApprovalList}
    ]

  operation :show,
    summary: "Get approval gate",
    description: "Returns a single approval gate by ID.",
    tags: ["Approvals"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Approval gate ID"]
    ],
    responses: [
      ok: {"Approval gate", "application/json", Schemas.ApprovalGate},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]

  operation :request,
    summary: "Request approval",
    description: "Creates a new approval gate for a tool invocation. Notifies connected dashboards via PubSub.",
    tags: ["Approvals"],
    request_body: {"Approval request", "application/json", Schemas.ApprovalRequestBody, required: true},
    responses: [
      created: {"Gate created", "application/json", Schemas.ApprovalRequestResult}
    ]

  operation :approve,
    summary: "Approve a gate",
    description: "Marks an approval gate as approved. Broadcasts decision via PubSub.",
    tags: ["Approvals"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Approval gate ID"]
    ],
    request_body: {"Approve body", "application/json", Schemas.ApproveBody, required: false},
    responses: [
      ok: {"Decision result", "application/json", Schemas.ApprovalDecisionResult},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse},
      conflict: {"Not pending", "application/json", Schemas.ErrorResponse}
    ]

  operation :reject,
    summary: "Reject a gate",
    description: "Marks an approval gate as rejected with an optional reason.",
    tags: ["Approvals"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Approval gate ID"]
    ],
    request_body: {"Reject body", "application/json", Schemas.RejectBody, required: false},
    responses: [
      ok: {"Decision result", "application/json", Schemas.ApprovalDecisionResult},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse},
      conflict: {"Not pending", "application/json", Schemas.ErrorResponse}
    ]

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

  # api-s5 Wave 1: catch-all for non-annotated actions.
  def open_api_operation(_action), do: nil
end
