defmodule Apm.AuditLog.Sinks.EventStoreSink do
  @moduledoc """
  PostgreSQL WORM (Write-Once-Read-Many) audit backend via EventStore (CP-287).

  ## Opt-in configuration

  This sink is **disabled by default**. To enable it, add:

      config :apm, :audit_backend, :eventstore

  When the backend is `:ets` (default) `push_event/1` is a no-op returning `:ok`
  immediately, so wiring the sink into `audit_sinks` has zero production overhead
  until you opt in.

  ## EventStore setup

  See `docs/migrations/audit-eventstore-setup.md` for database provisioning and
  configuration. You must have the `eventstore` Hex package in `deps` and a
  running PostgreSQL instance before enabling this backend.

  ## Stream naming

  Events are appended to a stream named after their `event_type`:

      "audit:" <> event_type  e.g. "audit:auth:authorize"

  If `event_type` is absent, the stream falls back to `"audit:events"`.

  ## Adapter injection

  For test isolation (no PostgreSQL required), the adapter function can be
  replaced via config:

      config :apm, :event_store_adapter_fn, fn stream, version, events, opts ->
        EventStore.append_to_stream(stream, version, events, opts)
      end

  The default adapter calls `EventStore.append_to_stream/4` directly. This
  allows tests to inject a capture function without pulling in EventStore deps.

  ## Behaviour

  Implements `Apm.AuditLog.Sink`. Return `:ok` on success, `{:error, reason}`
  on failure. Never raises.
  """

  @behaviour Apm.AuditLog.Sink

  require Logger

  @stream_prefix "audit"
  @fallback_stream "audit:events"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns `true` when `:audit_backend` is configured as `:eventstore`.
  """
  @spec backend_enabled?() :: boolean()
  def backend_enabled? do
    Application.get_env(:apm, :audit_backend, :ets) == :eventstore
  end

  @impl true
  @spec push_event(map()) :: :ok | {:error, term()}
  def push_event(event) do
    if backend_enabled?() do
      do_append(event)
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp do_append(event) do
    stream_id = stream_id_for(event)
    event_record = build_event_record(event)
    adapter_fn = resolve_adapter()

    try do
      case adapter_fn.(stream_id, :any_version, [event_record], []) do
        :ok ->
          :ok

        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("[EventStoreSink] append failed: #{inspect(reason)} stream=#{stream_id}")
          {:error, reason}

        other ->
          Logger.warning("[EventStoreSink] unexpected adapter result: #{inspect(other)}")
          {:error, {:unexpected_result, other}}
      end
    rescue
      e ->
        Logger.warning("[EventStoreSink] adapter raised: #{inspect(e)}")
        {:error, {:exception, e}}
    end
  end

  defp stream_id_for(%{event_type: event_type}) when is_binary(event_type) do
    "#{@stream_prefix}:#{event_type}"
  end

  defp stream_id_for(%{event_type: event_type}) when is_atom(event_type) do
    "#{@stream_prefix}:#{event_type}"
  end

  defp stream_id_for(_), do: @fallback_stream

  defp build_event_record(event) do
    event_type = Map.get(event, :event_type, "audit:event") |> to_string()
    event_id = Map.get(event, :event_id, generate_id())

    %{
      event_type: event_type,
      event_id: event_id,
      data: event,
      metadata: %{
        inserted_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        source: "ccem-apm-audit"
      }
    }
  end

  # Resolve the append function — injectable for testing.
  # Production: EventStore.append_to_stream/4 (requires :eventstore dep + DB).
  # Test: a capture lambda injected via Application.put_env/3.
  defp resolve_adapter do
    Application.get_env(:apm, :event_store_adapter_fn) ||
      (&default_adapter/4)
  end

  defp default_adapter(stream_id, expected_version, events, opts) do
    # Guard: only call if EventStore module is available (opt-in dep).
    # Falls back gracefully if :eventstore is not in deps.
    if Code.ensure_loaded?(EventStore) and function_exported?(EventStore, :append_to_stream, 4) do
      apply(EventStore, :append_to_stream, [stream_id, expected_version, events, opts])
    else
      Logger.warning(
        "[EventStoreSink] EventStore module not available. " <>
          "Add `{:eventstore, \"~> 1.4\"}` to mix.exs deps and configure a PostgreSQL database. " <>
          "See docs/migrations/audit-eventstore-setup.md"
      )

      {:error, :eventstore_not_loaded}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
