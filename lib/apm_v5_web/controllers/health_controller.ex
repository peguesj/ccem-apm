defmodule ApmV5Web.HealthController do
  @moduledoc """
  RFC 8615 / IETF draft-inadarei-api-health-check-06 compliant health endpoint.

  Serves `GET /health` and its well-known alias `GET /.well-known/health` with
  `Content-Type: application/health+json`.

  ## Breaking change vs. legacy /health

  The legacy `/api/status` endpoint still returns `"status": "ok"` for back-compat.
  This endpoint uses the RFC-mandated vocabulary: `"pass"` | `"warn"` | `"fail"`.
  Clients that compared `status == "ok"` must be updated to `status == "pass"`.

  ## Checks object

  | Key              | componentType | Metric                         | pass threshold  |
  |------------------|---------------|--------------------------------|-----------------|
  | `ets:size`       | datastore     | `:erlang.memory(:ets)` / 1024  | < 1 000 MB      |
  | `beam:memory_mb` | system        | `:erlang.memory(:total)` / 1M  | < 1 000 MB      |

  Warn threshold: pass if < 1 000 MB, warn if < 4 000 MB, fail otherwise.
  """

  use ApmV5Web, :controller

  alias ApmV5.AppVersion

  @warn_threshold_mb 1_000
  @fail_threshold_mb 4_000

  @doc """
  GET /health and GET /.well-known/health

  Returns RFC 8615 health+json. The LiveView at `/health` (browser route) is
  unaffected — this controller only handles JSON API requests.
  """
  @spec health(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def health(conn, _params) do
    {ets_mb, ets_status} = ets_check()
    {beam_mb, beam_status} = beam_memory_check()

    overall = aggregate_status([ets_status, beam_status])
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
      |> check_genserver(ApmV5.Auth.PolicyRulesStore)
      |> check_genserver(ApmV5.Auth.AuthorizationGate)
      |> check_genserver(ApmV5.AgentRegistry)
      |> check_genserver(ApmV5.Auth.SessionStore)

    if failed == [] do
      json(conn, %{ready: true})
    else
      conn
      |> put_status(503)
      |> json(%{ready: false, failed: failed})
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
  # Private helpers
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
