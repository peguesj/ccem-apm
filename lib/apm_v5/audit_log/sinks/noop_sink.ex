defmodule ApmV5.AuditLog.Sinks.NoopSink do
  @moduledoc """
  No-op audit sink — silently accepts every event and returns `:ok`.

  Intended for use in tests and development environments where real delivery
  to an external system is undesirable.  Also serves as a minimal reference
  implementation of the `ApmV5.AuditLog.Sink` behaviour.

  ## Configuration example

      # config/test.exs
      config :apm_v5, :audit_sinks, [ApmV5.AuditLog.Sinks.NoopSink]
  """

  @behaviour ApmV5.AuditLog.Sink

  @impl true
  @spec push_event(map()) :: :ok
  def push_event(_event), do: :ok
end
