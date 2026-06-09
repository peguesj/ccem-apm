defmodule Apm.Metrics do
  @moduledoc """
  CCEM APM Prometheus metrics definitions.

  Defines the `ccem_apm_*` metric family reported via peep at `/metrics`.
  This module is started as a supervised `Peep` reporter child and its
  ETS storage is scraped by `Peep.Plug` mounted at `/metrics` in the router.

  ## Metrics

  | Name | Type | Tags |
  |------|------|------|
  | `ccem_agent_registrations_total` | counter | project, formation_role |
  | `ccem_tool_call_duration_milliseconds` | distribution | tool_name, session_id |
  | `ccem_token_usage_total` | counter | model, project, token_type |
  | `ccem_formation_agents_active` | last_value | formation_id |
  | `ccem_approval_decision_duration_milliseconds` | distribution | decision |

  ## Supervisor Integration

  `Apm.Metrics` is started as a child of `ApmWeb.Telemetry` via:

      {Peep, name: :ccem_apm_metrics, metrics: Apm.Metrics.metrics()}

  ## Prometheus Endpoint

  `Peep.Plug` is mounted at `/metrics` in the router under a dedicated
  `:metrics_internal` pipeline. The route is intentionally outside the
  `:api` pipeline (which enforces `ApiAuth`) so that Prometheus scrapers
  can access the endpoint without a bearer token — restrict at the
  load-balancer / network layer in production.

  ## Usage Example

  Emit a tool call duration measurement from application code:

      :telemetry.execute(
        [:ccem, :tool_call, :stop],
        %{duration: System.monotonic_time() - t0},
        %{tool_name: "Bash", session_id: "s-abc"}
      )
  """

  import Telemetry.Metrics

  @doc """
  Returns the list of `Telemetry.Metrics` definitions consumed by peep.
  """
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      # ── Agent lifecycle ────────────────────────────────────────────────────
      counter(
        "ccem.agent.registrations.total",
        event_name: [:ccem, :agent, :registered],
        measurement: :count,
        tags: [:project, :formation_role],
        description: "Total number of agent registrations, by project and formation role.",
        reporter_options: [prometheus_type: :counter]
      ),

      # ── Tool call latency ──────────────────────────────────────────────────
      distribution(
        "ccem.tool_call.duration.milliseconds",
        event_name: [:ccem, :tool_call, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:tool_name, :session_id],
        description: "Tool call duration in milliseconds, by tool name and session.",
        reporter_options: [buckets: [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000]]
      ),

      # ── Token usage ────────────────────────────────────────────────────────
      counter(
        "ccem.token.usage.total",
        event_name: [:ccem, :token, :usage],
        measurement: :count,
        tags: [:model, :project, :token_type],
        description:
          "Cumulative token usage by model, project and type (input/output/cache_read/cache_creation).",
        reporter_options: [prometheus_type: :counter]
      ),

      # ── Formation active agent gauge ───────────────────────────────────────
      last_value(
        "ccem.formation.agents.active",
        event_name: [:ccem, :formation, :agents, :gauge],
        measurement: :count,
        tags: [:formation_id],
        description: "Current number of active agents in a formation.",
        reporter_options: [prometheus_type: :gauge]
      ),

      # ── Approval decision latency ──────────────────────────────────────────
      distribution(
        "ccem.approval.decision.duration.milliseconds",
        event_name: [:ccem, :approval, :decision, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:decision],
        description:
          "Time between approval request and decision (approve/deny/auto_approve) in milliseconds.",
        reporter_options: [buckets: [100, 500, 1_000, 5_000, 15_000, 30_000, 60_000]]
      )
    ]
  end

  @doc """
  Returns the child spec for the peep reporter supervisor child.

  Add to `ApmWeb.Telemetry.init/1` children list:

      Apm.Metrics.child_spec()
  """
  @spec child_spec() :: Supervisor.child_spec()
  def child_spec do
    {Peep, name: :ccem_apm_metrics, metrics: metrics()}
  end
end
