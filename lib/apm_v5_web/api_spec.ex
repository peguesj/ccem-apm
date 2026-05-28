defmodule ApmV5Web.ApiSpec do
  @moduledoc """
  OpenAPI spec entry point for CCEM APM (CP-262 / US-494 / api-s5 + comp-gov4 / CP-228 / US-460).

  This module satisfies the `OpenApiSpex.OpenApi` behaviour so the library's
  plug infrastructure (spec cache, `CastAndValidate`) can introspect the spec
  at runtime.

  ## Design

  Two sources are merged:

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

  ## Why `replace_params: false`

  `CastAndValidate` defaults to replacing `conn.params` with cast values when
  an operation is matched. Setting `replace_params: false` means unannotated
  routes keep their raw params unchanged, which is essential while annotation
  is in progress.
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

        Annotated routes use open_api_spex ControllerSpecs (Wave 1: 4 controllers).
        Remaining routes are served by the existing build_spec/0 (full hand-authored
        spec at GET /api/v2/openapi.json) until api-s7 (v9.4.0).
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
