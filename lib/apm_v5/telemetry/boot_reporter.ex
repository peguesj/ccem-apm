defmodule ApmV5.Telemetry.BootReporter do
  @moduledoc """
  Reports APM startup progress via PubSub notifications (US-604).

  Subscribes to apm:boot events emitted by StatusCache and PortManager (and
  other warmup sources) and re-broadcasts on apm:notifications for LiveView
  consumption. Also tracks a compact boot timeline for observability.

  ## Events tracked

    - :cache_warmup_started       — StatusCache began warming :status/:health
    - :cache_warmup_complete      — one of the warmup payloads landed in ETS
    - :port_scan_complete         — PortManager's first lsof returned
    - :first_request_served       — first /api/status reached a warm cache

  Each event writes a row to :ets.tab :apm_boot_timeline for postmortem query.
  """

  use GenServer
  require Logger

  @table :apm_boot_timeline

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record an ad-hoc boot event (for non-PubSub emitters)."
  @spec record(atom(), map()) :: :ok
  def record(event, meta \\ %{}) when is_atom(event) and is_map(meta) do
    GenServer.cast(__MODULE__, {:record, event, meta})
  end

  @doc "Return all recorded boot events in insertion order."
  @spec timeline() :: [{atom(), map(), integer()}]
  def timeline do
    case :ets.info(@table) do
      :undefined ->
        []

      _ ->
        @table
        |> :ets.tab2list()
        |> Enum.sort_by(fn {_event, _meta, ts} -> ts end)
    end
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :duplicate_bag, :public, read_concurrency: true])
    # Subscribe to the apm:boot topic to capture warmup events broadcast by
    # StatusCache + PortManager + etc.
    try do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:boot")
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    record_internal(:boot_reporter_started, %{})
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:record, event, meta}, state) do
    record_internal(event, meta)
    {:noreply, state}
  end

  @impl true
  def handle_info({:status_cache_warmup_started, _ts}, state) do
    record_internal(:cache_warmup_started, %{source: :status_cache})
    emit_notification("APM cache warmup started", "StatusCache building hot payloads", :info)
    {:noreply, state}
  end

  @impl true
  def handle_info({:status_cache_warmup_complete, key, _ts}, state) do
    record_internal(:cache_warmup_complete, %{key: key, source: :status_cache})

    emit_notification(
      "APM cache warm",
      "StatusCache #{key} payload ready",
      :info
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:port_scan_complete, count}, state) do
    record_internal(:port_scan_complete, %{count: count})

    emit_notification(
      "APM port scan complete",
      "#{count} active ports discovered",
      :info
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:first_request_served, path, latency_ms}, state) do
    record_internal(:first_request_served, %{path: path, latency_ms: latency_ms})

    emit_notification(
      "APM first request served",
      "#{path} warm-cache hit in #{latency_ms}ms",
      :info
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp record_internal(event, meta) do
    ts = System.monotonic_time(:millisecond)
    :ets.insert(@table, {event, meta, ts})
    Logger.debug("[BootReporter] #{event} #{inspect(meta)}")
    :ok
  end

  defp emit_notification(title, message, severity) do
    notif = %{
      type: "info",
      title: title,
      message: message,
      category: "system",
      severity: to_string(severity),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    try do
      Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:notifications", {:boot_event, notif})
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end
