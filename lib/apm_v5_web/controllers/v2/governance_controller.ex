defmodule ApmV5Web.V2.GovernanceController do
  @moduledoc """
  REST API controller for governance and compliance endpoints.

  ## Endpoints

    * `GET /api/v2/governance/controls` — full control registry with
      framework cross-references.

  Spec: CP-229 / US-461 / Plane df4af43a
  """

  use ApmV5Web, :controller

  alias ApmV5.Governance.ControlRegistry

  @doc """
  GET /api/v2/governance/controls

  Returns the full ControlRegistry as JSON. Response shape:

  ```json
  {
    "controls": [
      {
        "id": "policy_engine",
        "name": "PolicyEngine",
        "description": "...",
        "status": "satisfied",
        "frameworks": {
          "nist_ai_rmf": ["GV-1.1", "GV-2.1"],
          "soc2": ["CC6.1"],
          "iso_27001": ["A.9"]
        }
      }
    ],
    "frameworks": {
      "nist_ai_rmf": {"GV-1.1": ["policy_engine", "policy_decision_store"], ...},
      "soc2": {"CC6.1": ["policy_engine", "authorization_gate"], ...}
    }
  }
  ```
  """
  def list_controls(conn, _params) do
    controls =
      ControlRegistry.list_controls()
      |> Enum.map(fn {id, ctrl} ->
        frameworks =
          ctrl
          |> Map.drop([:name, :description, :status])
          |> Map.new(fn {k, v} -> {to_string(k), v} end)

        %{
          id: to_string(id),
          name: ctrl.name,
          description: ctrl.description,
          status: to_string(ctrl.status),
          frameworks: frameworks
        }
      end)
      |> Enum.sort_by(& &1.id)

    json(conn, %{
      controls: controls,
      frameworks: ControlRegistry.framework_index()
    })
  end
end
