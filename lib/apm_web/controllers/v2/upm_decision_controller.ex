defmodule ApmWeb.V2.UpmDecisionController do
  @moduledoc """
  REST controller for UPM Decision Gate endpoints.

  POST /api/v2/upm/gate       — create a blocking decision request (up to 120s)
  GET  /api/v2/upm/gates      — list all gates (pending + resolved)
  GET  /api/v2/upm/gates/:id  — get a specific gate
  POST /api/v2/upm/gate/:id/approve — approve a pending gate
  POST /api/v2/upm/gate/:id/reject  — reject a pending gate

  Used by /upm plan before deploying a formation. The POST /api/v2/upm/gate
  call blocks until the user responds via CCEMHelper notification action or
  osascript dialog, then returns the decision.
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmWeb.Plugs.OpenApiErrorRenderer

  alias Apm.Upm.DecisionGate
  alias ApmWeb.Schemas

  @doc "Create a decision gate and block until resolved (or timeout)."
  operation :create,
    summary: "Create",
    tags: ["UPM Decision Gate"],
    responses: [
      ok: {"OK", "application/json", Schemas.GateDecision}
    ]

  def create(conn, params) do
    question = Map.get(params, "question", "Proceed with formation deployment?")
    opts = %{
      "context" => Map.get(params, "context", ""),
      "options" => Map.get(params, "options", ["Deploy", "Cancel"]),
      "timeout_ms" => Map.get(params, "timeout_ms", 120_000)
    }

    case DecisionGate.request(question, opts) do
      {:approved, method} ->
        json(conn, %{decision: "approved", method: method, question: question})

      {:rejected, reason} ->
        json(conn, %{decision: "rejected", reason: reason, question: question})

      {:timeout, gate_id} ->
        conn
        |> put_status(408)
        |> json(%{decision: "timeout", gate_id: gate_id, question: question})
    end
  end

  @doc "List all decision gates."
  operation :index,
    summary: "List",
    tags: ["UPM Decision Gate"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def index(conn, _params) do
    gates =
      DecisionGate.list_pending()
      |> Enum.map(&serialize_gate/1)

    json(conn, %{gates: gates, pending_count: length(gates)})
  end

  @doc "Get a specific gate by ID."
  operation :show,
    summary: "Get one",
    tags: ["UPM Decision Gate"],
    responses: [
      ok: {"OK", "application/json", Schemas.Gate}
    ]

  def show(conn, %{"id" => gate_id}) do
    case DecisionGate.get(gate_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "gate not found"})

      gate ->
        json(conn, serialize_gate(gate))
    end
  end

  @doc "Approve a pending gate."
  operation :approve,
    summary: "Approve",
    tags: ["UPM Decision Gate"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def approve(conn, %{"id" => gate_id}) do
    case DecisionGate.approve(gate_id) do
      :ok ->
        json(conn, %{ok: true, gate_id: gate_id, decision: "approved"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "gate not found"})

      {:error, :not_pending} ->
        conn |> put_status(409) |> json(%{error: "gate is not pending"})
    end
  end

  @doc "Reject a pending gate."
  operation :reject,
    summary: "Reject",
    tags: ["UPM Decision Gate"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def reject(conn, %{"id" => gate_id} = params) do
    reason = Map.get(params, "reason", "User rejected")

    case DecisionGate.reject(gate_id, reason) do
      :ok ->
        json(conn, %{ok: true, gate_id: gate_id, decision: "rejected", reason: reason})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "gate not found"})

      {:error, :not_pending} ->
        conn |> put_status(409) |> json(%{error: "gate is not pending"})
    end
  end

  # -- Private ----------------------------------------------------------------

  defp serialize_gate(gate) do
    %{
      gate_id: gate.gate_id,
      question: gate.question,
      context: gate.context,
      options: gate.options,
      status: gate.status,
      decision: gate.decision,
      method: gate.method,
      requested_at: gate.requested_at,
      resolved_at: gate.resolved_at
    }
  end
end
