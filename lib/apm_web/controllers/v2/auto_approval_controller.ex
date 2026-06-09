defmodule ApmWeb.V2.AutoApprovalController do
  @moduledoc """
  REST API controller for auto-approval policy management.

  Endpoints:
  - GET /api/v2/auth/auto-approval-policies — list active policies
  - POST /api/v2/auth/auto-approval-policies — create new policy
  - PATCH /api/v2/auth/auto-approval-policies/:id — update policy
  - DELETE /api/v2/auth/auto-approval-policies/:id — delete policy
  - POST /api/v2/auth/auto-approval-policies/:id/test — test policy matching (dry-run)
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmWeb.Plugs.OpenApiErrorRenderer

  require Logger

  alias Apm.Auth.AutoApprovalStore

  @doc "List all active auto-approval policies."
  operation(:index,
    summary: "List",
    tags: ["Approvals"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def index(conn, _params) do
    policies = AutoApprovalStore.list_active()
    json(conn, %{policies: policies, count: length(policies)})
  end

  @doc "Get a specific auto-approval policy by ID."
  operation(:show,
    summary: "Get one",
    tags: ["Approvals"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def show(conn, %{"id" => policy_id}) do
    case AutoApprovalStore.get(policy_id) do
      nil -> send_resp(conn, 404, Jason.encode!(%{error: "not_found"}))
      policy -> json(conn, %{policy: policy})
    end
  end

  @doc """
  Create a new auto-approval policy.

  Request body:
  {
    "agent_id": null | string,
    "formation_id": null | string,
    "session_id": null | string,
    "project": null | string,
    "allowed_tools": :all | [string],
    "allowed_risk_levels": :all | [string],
    "reason": string,
    "created_by": string (optional)
  }
  """
  operation(:create,
    summary: "Create",
    tags: ["Approvals"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def create(conn, params) do
    attrs = extract_policy_attrs(params)

    case AutoApprovalStore.create(attrs) do
      {:ok, policy_id} ->
        policy = AutoApprovalStore.get(policy_id)
        send_resp(conn, 201, Jason.encode!(%{policy_id: policy_id, policy: policy}))

      {:error, reason} ->
        send_resp(conn, 400, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  @doc """
  Update an existing auto-approval policy.

  Allowed updates: reason, allowed_tools, allowed_risk_levels, expires_at
  """
  operation(:update,
    summary: "Update",
    tags: ["Approvals"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def update(conn, %{"id" => policy_id} = params) do
    updates = extract_policy_attrs(params, :update)

    case AutoApprovalStore.update(policy_id, updates) do
      {:ok, updated_policy} ->
        json(conn, %{policy: updated_policy})

      {:error, :not_found} ->
        send_resp(conn, 404, Jason.encode!(%{error: "not_found"}))
    end
  end

  @doc "Delete an auto-approval policy by ID."
  operation(:delete,
    summary: "Delete",
    tags: ["Approvals"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def delete(conn, %{"id" => policy_id}) do
    case AutoApprovalStore.delete(policy_id) do
      :ok ->
        send_resp(conn, 200, Jason.encode!(%{message: "deleted"}))

      {:error, :not_found} ->
        send_resp(conn, 404, Jason.encode!(%{error: "not_found"}))
    end
  end

  @doc """
  Test if a policy would match a tool call (dry-run).

  Query params:
  - agent_id: string
  - formation_id: string (optional)
  - session_id: string (optional)
  - project: string (optional)
  - tool_name: string
  - risk_level: :low | :medium | :high | :critical

  Returns the matching policy or null.
  """
  operation(:test_match,
    summary: "Test match",
    tags: ["Approvals"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def test_match(conn, params) do
    agent_id = params["agent_id"]
    formation_id = params["formation_id"]
    session_id = params["session_id"]
    project = params["project"]
    tool_name = params["tool_name"]

    risk_level =
      case params["risk_level"] do
        str when is_binary(str) -> String.to_atom(str)
        atom when is_atom(atom) -> atom
        _ -> :low
      end

    case AutoApprovalStore.find_matching(
           agent_id,
           formation_id,
           session_id,
           project,
           tool_name,
           risk_level
         ) do
      nil ->
        json(conn, %{
          matched: false,
          agent_id: agent_id,
          formation_id: formation_id,
          session_id: session_id,
          project: project,
          tool_name: tool_name,
          risk_level: risk_level
        })

      policy ->
        json(conn, %{
          matched: true,
          policy_id: policy.policy_id,
          reason: policy.reason,
          created_by: policy.created_by,
          approval_count: policy.approval_count,
          agent_id: agent_id,
          formation_id: formation_id,
          session_id: session_id,
          project: project,
          tool_name: tool_name,
          risk_level: risk_level
        })
    end
  end

  # ── Private Helpers ──────────────────────────────────────────────────────────

  defp extract_policy_attrs(params, mode \\ :create) do
    attrs = %{}

    # Always allowed fields
    attrs =
      if mode == :create do
        attrs
        |> put_if_present(:agent_id, params["agent_id"])
        |> put_if_present(:formation_id, params["formation_id"])
        |> put_if_present(:formation_role, params["formation_role"])
        |> put_if_present(:session_id, params["session_id"])
        |> put_if_present(:project, params["project"])
        |> put_if_present(:created_by, params["created_by"])
      else
        attrs
      end

    # Updateable fields (create and update modes)
    attrs
    |> put_if_present(:allowed_tools, normalize_tools(params["allowed_tools"]))
    |> put_if_present(:allowed_risk_levels, normalize_risk_levels(params["allowed_risk_levels"]))
    |> put_if_present(:reason, params["reason"])
    |> put_if_present(:expires_at, normalize_datetime(params["expires_at"]))
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp normalize_tools(:all), do: :all
  defp normalize_tools("all"), do: :all
  defp normalize_tools(list) when is_list(list), do: list
  defp normalize_tools(_), do: :all

  defp normalize_risk_levels(:all), do: :all
  defp normalize_risk_levels("all"), do: :all

  defp normalize_risk_levels(list) when is_list(list) do
    Enum.map(list, fn
      str when is_binary(str) -> String.to_atom(str)
      atom when is_atom(atom) -> atom
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_risk_levels(_), do: :all

  defp normalize_datetime(nil), do: nil

  defp normalize_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp normalize_datetime(dt = %DateTime{}), do: dt
  defp normalize_datetime(_), do: nil
end
