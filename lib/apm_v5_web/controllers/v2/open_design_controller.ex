defmodule ApmV5Web.V2.OpenDesignController do
  @moduledoc false
  # Thin delegation shim — real implementation in ApmV5Web.OpenDesignController.
  use ApmV5Web, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmV5Web.Plugs.OpenApiErrorRenderer

  @ok_response [
    ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
  ]

  operation :health, summary: "Open Design health", tags: ["Open Design"], responses: @ok_response
  operation :agents, summary: "Open Design agents", tags: ["Open Design"], responses: @ok_response
  operation :skills, summary: "Open Design skills", tags: ["Open Design"], responses: @ok_response
  operation :skill_detail, summary: "Open Design skill detail", tags: ["Open Design"], responses: @ok_response
  operation :design_systems, summary: "Open Design design systems", tags: ["Open Design"], responses: @ok_response
  operation :design_system_detail, summary: "Open Design design system detail", tags: ["Open Design"], responses: @ok_response
  operation :projects, summary: "Open Design projects", tags: ["Open Design"], responses: @ok_response
  operation :project_detail, summary: "Open Design project detail", tags: ["Open Design"], responses: @ok_response
  operation :templates, summary: "Open Design templates", tags: ["Open Design"], responses: @ok_response

  defdelegate health(conn, params), to: ApmV5Web.OpenDesignController
  defdelegate agents(conn, params), to: ApmV5Web.OpenDesignController
  defdelegate skills(conn, params), to: ApmV5Web.OpenDesignController
  defdelegate skill_detail(conn, params), to: ApmV5Web.OpenDesignController
  defdelegate design_systems(conn, params), to: ApmV5Web.OpenDesignController
  defdelegate design_system_detail(conn, params), to: ApmV5Web.OpenDesignController
  defdelegate projects(conn, params), to: ApmV5Web.OpenDesignController
  defdelegate project_detail(conn, params), to: ApmV5Web.OpenDesignController
  defdelegate templates(conn, params), to: ApmV5Web.OpenDesignController
end
