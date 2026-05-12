defmodule ApmV5Web.V2.OpenDesignController do
  @moduledoc false
  # Thin delegation shim — real implementation in ApmV5Web.OpenDesignController.
  use ApmV5Web, :controller

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
