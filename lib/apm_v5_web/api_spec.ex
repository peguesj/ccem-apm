defmodule ApmV5Web.ApiSpec do
  @moduledoc """
  OpenAPI spec entry point for CCEM APM (CP-262 / US-494 / api-s5 + comp-gov4 / CP-228 / US-460).

  This module satisfies the `OpenApiSpex.OpenApi` behaviour so the library's
  plug infrastructure (spec cache, `CastAndValidate`) can introspect the spec
  at runtime.

  ## Design

  All routes annotated with `open_api_spex` ControllerSpecs as of api-s7 Wave 2b
  (CP-288, v9.4.0). `build_spec/0` has been deleted from `ApiV2Controller`.

  Annotated controllers:
  - Wave 1 (api-s5): ApiV2Controller, AuthController, ApprovalController, AgentControlController
  - Wave 2a (api-s7): All 37 v2 controllers + 22 Legacy<Name> schemas
  - Wave 2b (api-s7): All v1 controllers (ApiController, SkillsController, UpmApiController,
    UpmController, FormationApiController, ShowcaseApiController, UsageController,
    AgUiController, A2uiController, HealthController, MetricsController)

  The live spec endpoint remains at `GET /api/v2/openapi.json` served by
  `ApiV2Controller.openapi/2`, which now delegates to `ApmV5Web.ApiSpec.spec/0`.

  ## Why `replace_params: false`

  `CastAndValidate` defaults to replacing `conn.params` with cast values when
  an operation is matched. Setting `replace_params: false` preserves raw params
  for backward compatibility with existing controller action heads.
  """

  alias OpenApiSpex.{Info, OpenApi, Paths, Server}
  alias ApmV5Web.Router

  @behaviour OpenApiSpex.OpenApi

  @impl OpenApiSpex.OpenApi
  @spec spec() :: OpenApi.t()
  def spec do
    %OpenApi{
      info: %Info{
        title: "CCEM APM API",
        version: ApmV5.AppVersion.current(),
        description: """
        CCEM Agent Performance & Management — real-time monitoring, AgentLock
        authorization, Plugin Engine, and formation orchestration.

        All routes annotated with open_api_spex ControllerSpecs (api-s7 Wave 2b / CP-288).
        build_spec/0 deleted. This module is the single source of truth for the
        OpenAPI 3.0.3 spec served at GET /api/v2/openapi.json.
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
