defmodule ApmV5Web.MetricsController do
  @moduledoc """
  Serves Prometheus-format metrics at `GET /metrics`.

  Reads from the peep ETS reporter named `:ccem_apm_metrics` (started in
  `ApmV5Web.Telemetry`) and renders the standard Prometheus text exposition
  format (text/plain; version=0.0.4).

  This endpoint is intentionally outside the `:api` pipeline (no bearer token
  required) so that Prometheus scrapers can reach it without credentials.
  Restrict access at the load-balancer or network layer in production.

  ## obs-s2 / CP-217 / US-449
  """

  use ApmV5Web, :controller

  require Logger

  @peep_worker :ccem_apm_metrics

  @doc """
  Render all registered CCEM APM metrics in Prometheus text format.

  Returns `200 text/plain` with `# HELP` and `# TYPE` lines followed by
  metric samples. Returns `503 text/plain` if the peep reporter is not yet
  started (during application boot) or has crashed.
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    case safe_export() do
      {:ok, body} ->
        conn
        |> put_resp_content_type("text/plain; version=0.0.4")
        |> send_resp(200, body)

      {:error, reason} ->
        Logger.warning("[MetricsController] peep export failed: #{inspect(reason)}")

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(503, "# metrics unavailable: #{inspect(reason)}\n")
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp safe_export do
    body =
      @peep_worker
      |> Peep.get_all_metrics()
      |> Peep.Prometheus.export()

    {:ok, body}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
