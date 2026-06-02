defmodule ApmWeb.HealthController do
  @moduledoc """
  RFC 8615 / IETF draft-inadarei-api-health-check-06 compliant health endpoint.

  Serves `GET /health` and its well-known alias `GET /.well-known/health` with
  `Content-Type: application/health+json`.

  ## Breaking change vs. legacy /health

  The legacy `/api/status` endpoint still returns `"status": "ok"` for back-compat.
  This endpoint uses the RFC-mandated vocabulary: `"pass"` | `"warn"` | `"fail"`.
  Clients that compared `status == "ok"` must be updated to `status == "pass"`.

  ## Checks object

  | Key                          | componentType | Metric                                    | pass threshold            |
  |------------------------------|---------------|-------------------------------------------|---------------------------|
  | `ets:size`                   | datastore     | `:erlang.memory(:ets)` / 1024             | < 1 000 MB                |
  | `beam:memory_mb`             | system        | `:erlang.memory(:total)` / 1M             | < 1 000 MB                |
  | `beam:memory_processes`      | system        | `:erlang.memory(:processes_used)` / 1M    | informational             |
  | `beam:process_count`         | system        | `:erlang.system_info(:process_count)`     | warn ≥50% limit, fail ≥80%|
  | `beam:run_queue`             | system        | `:erlang.statistics(:run_queue)`          | warn > 10, fail > 100     |
  | `ets:audit_log_size`         | datastore     | `:ets.info(:apm_audit_log, :size)`        | informational             |
  | `ets:agent_registry_size`    | datastore     | `:ets.info(:apm_agents, :size)`           | informational             |
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias ApmWeb.Schemas
  alias OpenApiSpex.Schema
  alias Apm.AppVersion

  operation :health,
    summary: "RFC 8615 health check",
    description: """
    Returns RFC 8615 / IETF draft-inadarei-api-health-check-06 compliant health
    status with extended BEAM VM and ETS checks. Response uses `pass/warn/fail`
    vocabulary (not `ok`). Also served at GET `/.well-known/health`.
    """,
    tags: ["Health"],
    responses: [
      ok: {"Health+JSON response", "application/health+json", %Schema{
        type: :object,
        properties: %{
          status: %Schema{type: :string, enum: ["pass", "warn", "fail"]},
          version: %Schema{type: :string},
          checks: %Schema{type: :object, additionalProperties: true}
        },
        required: [:status, :version]
      }}
    ]

  operation :readiness,
    summary: "Kubernetes readiness probe",
    description: "Returns 200 when StatusCache is warm and critical GenServers are alive. Returns 503 with failed check names otherwise.",
    tags: ["Health"],
    responses: [
      ok: {"Ready", "application/json", %Schema{type: :object, properties: %{ready: %Schema{type: :boolean}}}},
      service_unavailable: {"Not ready", "application/json", %Schema{
        type: :object,
        properties: %{
          ready: %Schema{type: :boolean},
          failed: %Schema{type: :array, items: %Schema{type: :string}}
        }
      }}
    ]

  operation :startup,
    summary: "Kubernetes startup probe",
    description: "Returns 200 when the OTP supervision tree is fully initialized. Returns 503 while starting up.",
    tags: ["Health"],
    responses: [
      ok: {"Started", "application/json", %Schema{type: :object, properties: %{started: %Schema{type: :boolean}, phase: %Schema{type: :string}}}},
      service_unavailable: {"Starting", "application/json", %Schema{type: :object, additionalProperties: true}}
    ]

  operation :liveness,
    summary: "Kubernetes liveness probe",
    description: "Returns 200 when the BEAM is up and Phoenix is responding. Minimal body.",
    tags: ["Health"],
    responses: [
      ok: {"Alive", "application/json", Schemas.OkResponse}
    ]

  # Catch-all for any action not explicitly annotated above.
  def open_api_operation(_action), do: nil

  @warn_threshold_mb 1_000
  @fail_threshold_mb 4_000

  # beam:process_count thresholds as fraction of :process_limit
  @process_warn_fraction 0.50
  @process_fail_fraction 0.80

  # beam:run_queue thresholds
  @run_queue_warn 10
  @run_queue_fail 100

  @doc """
  GET /health and GET /.well-known/health

  Returns RFC 8615 health+json with extended Erlang VM and ETS checks.
  The LiveView at `/health` (browser route) is unaffected — this controller
  only handles JSON API requests.
  """
  @spec health(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def health(conn, _params) do
    {ets_mb, ets_status} = ets_check()
    {beam_mb, beam_status} = beam_memory_check()
    {proc_mb, _proc_status} = beam_memory_processes_check()
    {proc_count, proc_limit, proc_count_status} = beam_process_count_check()
    {run_queue, run_queue_status} = beam_run_queue_check()
    {audit_log_size, audit_log_status} = ets_table_size_check(:apm_audit_log)
    {agent_registry_size, agent_registry_status} = ets_table_size_check(:apm_agents)

    all_statuses = [
      ets_status,
      beam_status,
      proc_count_status,
      run_queue_status,
      audit_log_status,
      agent_registry_status
    ]

    overall = aggregate_status(all_statuses)
    version = AppVersion.current()
    now_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    payload = %{
      status: overall,
      version: version,
      releaseId: version,
      notes: [],
      output: "",
      checks: %{
        "ets:size" => [
          %{
            componentType: "datastore",
            observedValue: ets_mb,
            observedUnit: "MB",
            status: ets_status,
            time: now_iso
          }
        ],
        "beam:memory_mb" => [
          %{
            componentType: "system",
            observedValue: beam_mb,
            observedUnit: "MB",
            status: beam_status,
            time: now_iso
          }
        ],
        "beam:memory_processes" => [
          %{
            componentType: "system",
            observedValue: proc_mb,
            observedUnit: "MB",
            status: "pass",
            time: now_iso
          }
        ],
        "beam:process_count" => [
          %{
            componentType: "system",
            observedValue: proc_count,
            observedUnit: "processes",
            status: proc_count_status,
            time: now_iso,
            processLimit: proc_limit
          }
        ],
        "beam:run_queue" => [
          %{
            componentType: "system",
            observedValue: run_queue,
            observedUnit: "processes",
            status: run_queue_status,
            time: now_iso
          }
        ],
        "ets:audit_log_size" => [
          %{
            componentType: "datastore",
            observedValue: audit_log_size,
            observedUnit: "entries",
            status: audit_log_status,
            time: now_iso
          }
        ],
        "ets:agent_registry_size" => [
          %{
            componentType: "datastore",
            observedValue: agent_registry_size,
            observedUnit: "entries",
            status: agent_registry_status,
            time: now_iso
          }
        ]
      }
    }

    conn
    |> put_resp_content_type("application/health+json")
    |> json(payload)
  end

  @doc """
  GET /ready — Kubernetes readiness probe (CP-252 / US-484 / hc-s3).

  Returns 200 `{"ready": true}` when:
  - `StatusCache` ETS table (`:apm_status_cache`) has at least one warm entry
  - Critical GenServers are alive: `PolicyRulesStore`, `AuthorizationGate`,
    `AgentRegistry`, `SessionStore`

  Returns 503 with `{"ready": false, "failed": [...]}` listing each failed check
  by name, allowing operators and Kubernetes health-check dashboards to diagnose
  which component has not yet started.
  """
  @spec readiness(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def readiness(conn, _params) do
    failed =
      []
      |> check_status_cache_warm()
      |> check_genserver(Apm.Auth.PolicyRulesStore)
      |> check_genserver(Apm.Auth.AuthorizationGate)
      |> check_genserver(Apm.AgentRegistry)
      |> check_genserver(Apm.Auth.SessionStore)

    if failed == [] do
      json(conn, %{ready: true})
    else
      conn
      |> put_status(503)
      |> json(%{ready: false, failed: failed})
    end
  end

  @doc """
  GET /startup — Kubernetes startup probe (CP-253 / US-485 / hc-s4).

  Returns 200 `{"started": true, "phase": "running"}` when the OTP application
  supervision tree has fully initialized:
  - `:apm` appears in `:application.which_applications/0`
  - `Apm.Endpoint` process is alive (Phoenix is accepting requests)

  Returns 503 `{"started": false, "phase": "initializing", "failed": [...]}` while
  the application is still starting up.  Set `failureThreshold` high in the
  Kubernetes probe spec (e.g. 60) to allow for the full ~30 s cold-boot sequence.
  """
  @spec startup(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def startup(conn, _params) do
    failed =
      []
      |> check_application_started(:apm)
      |> check_endpoint_alive()

    if failed == [] do
      json(conn, %{started: true, phase: "running"})
    else
      conn
      |> put_status(503)
      |> json(%{started: false, phase: "initializing", failed: failed})
    end
  end

  @doc """
  GET /healthz — Kubernetes liveness probe.

  Returns 200 when the BEAM is up and Phoenix is responding. Kubernetes only
  checks the HTTP status code, so the body is kept minimal.

  Returns 503 only in the (theoretically unreachable) case where a fatal
  startup error condition is detected.
  """
  @spec liveness(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def liveness(conn, _params) do
    # If this action executes, the BEAM is running and the Phoenix endpoint is
    # serving requests — both required conditions for Kubernetes liveness.
    json(conn, %{ok: true})
  end

  # ---------------------------------------------------------------------------
  # Private helpers — readiness checks
  # ---------------------------------------------------------------------------

  @spec check_status_cache_warm([String.t()]) :: [String.t()]
  defp check_status_cache_warm(acc) do
    case :ets.info(:apm_status_cache, :size) do
      size when is_integer(size) and size > 0 -> acc
      _ -> ["status_cache:empty" | acc]
    end
  rescue
    _ -> ["status_cache:unavailable" | acc]
  end

  @spec check_genserver([String.t()], module()) :: [String.t()]
  defp check_genserver(acc, module) do
    case Process.whereis(module) do
      pid when is_pid(pid) -> acc
      nil -> [inspect(module) | acc]
    end
  end

  @spec check_application_started([String.t()], atom()) :: [String.t()]
  defp check_application_started(acc, app_name) do
    running_apps = :application.which_applications()

    if Enum.any?(running_apps, fn {name, _desc, _vsn} -> name == app_name end) do
      acc
    else
      ["application:#{app_name}:not_started" | acc]
    end
  end

  @spec check_endpoint_alive([String.t()]) :: [String.t()]
  defp check_endpoint_alive(acc) do
    case Process.whereis(ApmWeb.Endpoint) do
      pid when is_pid(pid) -> acc
      nil -> ["ApmWeb.Endpoint:not_alive" | acc]
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers — /api/health checks
  # ---------------------------------------------------------------------------

  @spec ets_check() :: {integer(), String.t()}
  defp ets_check do
    mb = div(:erlang.memory(:ets), 1_024)
    {mb, memory_status(mb)}
  end

  @spec beam_memory_check() :: {integer(), String.t()}
  defp beam_memory_check do
    mb = div(:erlang.memory(:total), 1_024 * 1_024)
    {mb, memory_status(mb)}
  end

  @spec beam_memory_processes_check() :: {integer(), String.t()}
  defp beam_memory_processes_check do
    mb = div(:erlang.memory(:processes_used), 1_024 * 1_024)
    {mb, "pass"}
  end

  @spec beam_process_count_check() :: {integer(), integer(), String.t()}
  defp beam_process_count_check do
    count = :erlang.system_info(:process_count)
    limit = :erlang.system_info(:process_limit)
    fraction = count / limit

    status =
      cond do
        fraction >= @process_fail_fraction -> "fail"
        fraction >= @process_warn_fraction -> "warn"
        true -> "pass"
      end

    {count, limit, status}
  end

  @spec beam_run_queue_check() :: {integer(), String.t()}
  defp beam_run_queue_check do
    run_queue = :erlang.statistics(:run_queue)

    status =
      cond do
        run_queue > @run_queue_fail -> "fail"
        run_queue > @run_queue_warn -> "warn"
        true -> "pass"
      end

    {run_queue, status}
  end

  @spec ets_table_size_check(atom()) :: {integer() | nil, String.t()}
  defp ets_table_size_check(table_name) do
    case :ets.info(table_name, :size) do
      size when is_integer(size) -> {size, "pass"}
      :undefined -> {nil, "pass"}
    end
  rescue
    _ -> {nil, "pass"}
  end

  @spec memory_status(integer()) :: String.t()
  defp memory_status(mb) when mb < @warn_threshold_mb, do: "pass"
  defp memory_status(mb) when mb < @fail_threshold_mb, do: "warn"
  defp memory_status(_mb), do: "fail"

  @spec aggregate_status([String.t()]) :: String.t()
  defp aggregate_status(statuses) do
    cond do
      Enum.any?(statuses, &(&1 == "fail")) -> "fail"
      Enum.any?(statuses, &(&1 == "warn")) -> "warn"
      true -> "pass"
    end
  end
end
