defmodule ApmV5Web.ApiSpec do
  @moduledoc """
  OpenAPI specification for CCEM APM, wired into `open_api_spex`.

  This module satisfies the `OpenApiSpex.OpenApi` behaviour so the library's
  plug infrastructure (spec cache, `CastAndValidate`) can introspect the spec
  at runtime.

  ## Design — Wave 1 (CP-228 / US-460)

  The existing hand-authored spec lives in
  `ApmV5Web.V2.ApiV2Controller` as a private `build_spec/0` function.
  Wave 1 does NOT migrate that spec — it only wires up:

    1. `OpenApiSpex.Plug.PutApiSpec` in the endpoint so the spec is cached.
    2. `OpenApiSpex.Plug.CastAndValidate` in the `:api` pipeline.

  `CastAndValidate` validates requests **only for paths annotated with
  `@operation`** on their controller action. Zero controllers are annotated in
  Wave 1, so the plug is a no-op for all 113 existing routes, preserving full
  backward-compatibility.

  Controller-level annotation (Wave 2 — api-s5 / api-s7) will incrementally
  populate `paths:` via the `@operation` macro; once all controllers are
  annotated the `build_spec/0` hand-authored map can be retired.

  ## Why `replace_params: false`

  `CastAndValidate` defaults to replacing `conn.params` with cast values when
  an operation is matched. Setting `replace_params: false` means unannotated
  routes keep their raw params unchanged, which is essential while annotation
  is in progress.
  """

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{Info, OpenApi, Server}

  @impl OpenApiSpex.OpenApi
  @spec spec() :: OpenApi.t()
  def spec do
    %OpenApi{
      info: %Info{
        title: "CCEM APM API",
        version: ApmV5.AppVersion.current(),
        description:
          "CCEM Agent Performance & Management — real-time monitoring, AgentLock " <>
            "authorization, Plugin Engine, and formation orchestration. " <>
            "Full hand-authored spec at GET /api/v2/openapi.json."
      },
      servers: [
        %Server{url: "http://localhost:3032", description: "Local APM server"}
      ],
      # Paths are empty in Wave 1. open_api_spex merges annotated @operation
      # definitions here automatically as controllers are annotated (Wave 2).
      paths: %{}
    }
  end
end
