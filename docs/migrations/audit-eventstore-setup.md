# Audit EventStore Backend Setup

**Feature**: CP-287 / audit-s9  
**Version**: v9.4.0  
**Backend**: PostgreSQL WORM via `eventstore ~> 1.4`

## Overview

The `EventStoreSink` provides an optional PostgreSQL-backed WORM (Write-Once-Read-Many)
audit trail. Events are appended to append-only event streams, providing tamper-evident
storage as a complement to the default ETS + JSONL backend.

This backend is **opt-in** — the default is `:ets`. Enabling it does not replace ETS
storage; it adds a parallel write path.

---

## Prerequisites

- PostgreSQL 12+ running and accessible
- Elixir `eventstore ~> 1.4` dependency in `mix.exs`
- Database credentials configured

---

## Step 1: Add the Dependency

In `mix.exs`, add `eventstore` to your `deps`:

```elixir
defp deps do
  [
    # ... existing deps ...
    {:eventstore, "~> 1.4", optional: true}
  ]
end
```

Run `mix deps.get`.

---

## Step 2: Configure EventStore

Add an EventStore configuration module:

```elixir
# lib/apm_v5/audit_log/event_store.ex
defmodule ApmV5.AuditLog.EventStoreRepo do
  use EventStore, otp_app: :apm_v5
end
```

Configure the connection in `config/config.exs`:

```elixir
config :apm_v5, ApmV5.AuditLog.EventStoreRepo,
  username: "postgres",
  password: "postgres",
  database: "apm_v5_audit_eventstore",
  hostname: "localhost",
  pool_size: 5
```

Add the repo to your application supervision tree in `lib/apm_v5/application.ex`:

```elixir
children = [
  # ... existing children ...
  ApmV5.AuditLog.EventStoreRepo
]
```

---

## Step 3: Create the Database

```bash
mix event_store.create
mix event_store.init
```

---

## Step 4: Enable the Backend

In `config/prod.exs` (or `config/runtime.exs`):

```elixir
# Enable EventStore WORM backend for audit events
config :apm_v5, :audit_backend, :eventstore

# Wire EventStoreSink into the audit sink pipeline
config :apm_v5, :audit_sinks, [
  ApmV5.AuditLog.Sinks.EventStoreSink
  # Add HttpSink here too for SIEM delivery if desired
]

# Point the adapter at your EventStore repo
config :apm_v5, :event_store_adapter_fn, fn stream_id, version, events, opts ->
  ApmV5.AuditLog.EventStoreRepo.append_to_stream(stream_id, version, events, opts)
end
```

---

## Step 5: Verify

Start the application and trigger an audit event:

```bash
curl -s -X POST http://localhost:3032/api/v2/auth/authorize \
  -H "Content-Type: application/json" \
  -d '{"agent_id":"test","session_id":"s1","tool_name":"Read","role":"agent"}'
```

Verify the event was appended:

```elixir
{:ok, events} = ApmV5.AuditLog.EventStoreRepo.read_stream_forward("audit:auth:authorize")
IO.inspect(length(events))  # should be >= 1
```

---

## Stream Naming Convention

| Event type pattern          | EventStore stream name          |
|-----------------------------|---------------------------------|
| `auth:authorize`            | `audit:auth:authorize`          |
| `auth:rate_limited`         | `audit:auth:rate_limited`       |
| `auth:tool_registered`      | `audit:auth:tool_registered`    |
| `:any_atom`                 | `audit:any_atom`                |
| (absent / unknown)          | `audit:events`                  |

---

## Test Isolation

In test environments, **do not** set `:audit_backend` to `:eventstore`. Instead,
inject a capture lambda:

```elixir
Application.put_env(:apm_v5, :audit_backend, :eventstore)
Application.put_env(:apm_v5, :event_store_adapter_fn, fn _stream, _version, _events, _opts ->
  :ok  # or send(self(), {:appended, events})
end)
```

This pattern is used throughout `audit_log_eventstore_sink_test.exs` and requires
no PostgreSQL.

---

## Rollback

To disable the EventStore backend:

```elixir
# config/prod.exs
config :apm_v5, :audit_backend, :ets
config :apm_v5, :audit_sinks, []
```

The ETS + JSONL backend continues to function independently. No data migration
is required when toggling between backends.
