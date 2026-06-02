# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :apm,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :apm, ApmWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ApmWeb.ErrorHTML, json: ApmWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Apm.PubSub,
  live_view: [signing_salt: "b6BgEvJs"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  apm: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  apm: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Register application/jsonl MIME type for A2UI endpoint
config :mime, :types, %{
  "application/jsonl" => ["jsonl"]
}

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# --- v9.3.0 Audit Sinks (audit-s7 / CP-225) ---
# Empty by default.  Override in prod.exs / runtime.exs to deliver events to
# external SIEM systems:
#
#   config :apm, :audit_sinks, [Apm.AuditLog.Sinks.HttpSink]
#
config :apm, :audit_sinks, []

# HttpSink defaults — endpoint_url is intentionally a placeholder.
# Override in prod.exs or runtime.exs for real deployments.
config :apm, Apm.AuditLog.Sinks.HttpSink,
  endpoint_url: "https://siem.example/audit",
  timeout_ms: 500,
  max_retries: 0

# ── coord-v10.0-d2 (CP-289): Horde + libcluster configuration skeleton ────────
#
# Backend selection: :ets (default, single-node) or :horde (multi-node).
# Set to :horde in production when running a multi-node cluster.
config :apm, :agent_registry_backend, :ets

# libcluster topology skeleton — DNS strategy (multi-node production default).
# Override in prod.exs or runtime.exs with actual service/namespace values.
#
# Example for Kubernetes headless service:
#
#   config :libcluster, :topologies, [
#     k8s_dns: [
#       strategy: Cluster.Strategy.Kubernetes.DNS,
#       config: [
#         service: "apm-v5-headless",
#         application_name: "apm",
#         polling_interval: 5_000
#       ]
#     ]
#   ]
#
# Example for Gossip (development/VM cluster):
#
#   config :libcluster, :topologies, [
#     dev_gossip: [
#       strategy: Cluster.Strategy.Gossip
#     ]
#   ]
config :libcluster, :topologies, []

# OPA sidecar client defaults (auth-v10.1-s1 / CP-291)
# Override base_url in dev.exs / prod.exs if sidecar runs on a different host.
config :apm, Apm.Auth.OpaClient,
  base_url: "http://localhost:8181",
  timeout_ms: 2_000

# PolicyPriorityResolver strategy (auth-v10.1-s4 / CP-294)
# :deny_wins | :most_specific | :first_match
config :apm, Apm.Auth.PolicyPriorityResolver, strategy: :deny_wins

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
