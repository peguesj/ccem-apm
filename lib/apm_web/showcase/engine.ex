defmodule ApmWeb.Showcase.Engine do
  @moduledoc """
  Behaviour for showcase engines mounted as project-scoped endpoints
  underneath /showcase/engines/* (browser) and /api/showcase/engines/* (REST).

  Showcase engines are thin host adapters that let an external skill (or its
  consumer-side standalone server) render a domain-specific visualization
  inside APM. APM hosts the route, enforces project scoping, persists the
  most recent payload, and renders chrome around the engine's payload view.
  Engines themselves stay small: they declare an id, a scoping policy, how
  to fetch and ingest their payload, and how to render it.

  ## Engine rendering trade-offs

  Engines have two practical render strategies:

    1. **Iframe the consumer's standalone server** — keeps APM lean. APM hosts
       the route, but the visualization lives in the consumer's local server.
       APM serves a thin chrome + iframe wrapper.

    2. **Render natively in APM** — bundle the React/JS asset(s) into APM
       priv/static and render through a LiveView component. Heavier integration,
       lower latency, no second port to keep alive.

  v1 of this pattern uses strategy (1). The FeatureFlow engine iframes the v2
  client's standalone server at http://127.0.0.1:<port> and only takes over
  routing and project-scoping. Future engines may opt into strategy (2).

  ## Project scoping

  Every engine declares a `project_scope/0`:

    * `:any`    — engine renders shared or cross-project data. Rare. The
                  active project context is informational only.
    * `:strict` — engine refuses to fetch or ingest a payload unless the
                  active APM project (per `Apm.ConfigLoader.get_active_project/0`)
                  matches the payload's declared `project_name`.

  The `ApmWeb.Showcase.ApiController` enforces this in `ingest/2` and
  `fetch_json/2` by rejecting mismatches with HTTP 403 and
  `{"error": "project_scope_mismatch"}`.
  """

  @doc """
  Engine identifier used in the URL path (e.g. "feature-flow").

  Must be URL-safe and stable across releases.
  """
  @callback id() :: String.t()

  @doc """
  Project scoping policy. See module docs.
  """
  @callback project_scope() :: :any | :strict

  @doc """
  Fetch the most recent payload for `project_name`.

  Returns `{:ok, payload}` if a payload exists. Returns `{:error, :not_found}`
  if no payload has been ingested yet, or any other `{:error, reason}` for
  storage/backend failures.

  `params` carries optional query string params (e.g. for engine-specific
  filtering). Engines may ignore.
  """
  @callback fetch(project_name :: String.t(), params :: map()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Render the engine's payload inside a LiveView. Receives the payload (as
  returned by `fetch/2`) and the live view assigns (which include the active
  project context, the current path, and any chrome assigns).
  """
  @callback render_payload(payload :: map(), assigns :: map()) ::
              Phoenix.LiveView.Rendered.t()

  @doc """
  Whether the engine accepts POST ingests.

  When `false`, the API ingest endpoint returns HTTP 405 for this engine.
  """
  @callback supports_post?() :: boolean()

  @doc """
  Ingest a payload from a consumer for `project_name`.

  Engines validate schema, normalize, and persist. Returns the canonicalized
  payload on success.
  """
  @callback ingest(project_name :: String.t(), payload :: map()) ::
              {:ok, term()} | {:error, term()}
end
