defmodule ApmV5.AuditLog.Sink do
  @moduledoc """
  Behaviour contract for audit event sinks.

  Each sink receives a fully-formed audit event map (including `self_hash` and
  all v2 attribution fields) after the event has been committed to ETS, disk,
  and PubSub.  Sink failures MUST NOT raise — returning `{:error, reason}` is
  the correct signal for non-fatal delivery failures.

  ## Implementing a Sink

      defmodule MyApp.AuditLog.Sinks.CustomSink do
        @behaviour ApmV5.AuditLog.Sink

        @impl true
        def push_event(event) do
          # deliver event to external system …
          :ok
        end
      end

  ## Registration

  Register sinks in your application config:

      config :apm_v5, :audit_sinks, [MyApp.AuditLog.Sinks.CustomSink]

  Each configured sink module is called via `Task.start/1` (fire-and-forget)
  after every audit event, so sink latency never blocks the `AuditLog` GenServer.
  """

  @doc """
  Push a single audit event to the external sink.

  The `event` map contains all fields defined in the v2 audit schema, including
  `:self_hash`, `:agent_id`, `:session_id`, `:formation_id`, and `:wave`.

  Return `:ok` on success or `{:error, reason}` on failure.  Do NOT raise —
  exceptions are caught by the fire-and-forget `Task` wrapper and logged as
  warnings, but raising is still considered a sink bug.
  """
  @callback push_event(event :: map()) :: :ok | {:error, term()}
end
