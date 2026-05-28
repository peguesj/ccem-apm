defmodule ApmV5Web.ApiSpec do
  @moduledoc """
  OpenAPI spec entry point for CCEM APM (CP-262 / US-494 / api-s5 Wave 1).

  This module merges two sources:
  1. `open_api_spex` annotations from controllers using `ControllerSpecs`
     (Wave 1: ApiV2Controller, AuthController, ApprovalController,
      AgentControlController — partial annotation)
  2. The existing `build_spec/0` output from `ApiV2Controller` for all
     non-annotated routes (fallback until api-s7 Wave 2 in v9.4.0)

  The live spec endpoint remains at `GET /api/v2/openapi.json` served by
  `ApiV2Controller.openapi/2`. The `spec/0` function here is the canonical
  `open_api_spex` entry point used by `CastAndValidate` plug and
  `OpenApiSpex.TestAssertions` (api-s6).

  ## Migration Plan
  - api-s5 (this story): annotate 4 core controllers, ~20 actions total
  - api-s6: add `OpenApiSpex.TestAssertions` response contract tests
  - api-s7 (v9.4.0): annotate all remaining 20+ controllers, delete `build_spec/0`
  """

  alias OpenApiSpex.{Info, OpenApi, Paths, Server}
  alias ApmV5Web.Router

  @behaviour OpenApiSpex.OpenApi

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "CCEM APM API",
        version: Application.spec(:apm_v5, :vsn) |> to_string(),
        description: """
        CCEM Agent Performance Monitor REST API.
        Annotated routes use open_api_spex ControllerSpecs (Wave 1: 4 controllers).
        Remaining routes are served by the existing build_spec/0 until api-s7 (v9.4.0).
        """
      },
      servers: [
        %Server{url: "http://localhost:3032", description: "Local APM server"}
      ],
      paths: Paths.from_router(Router)
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
