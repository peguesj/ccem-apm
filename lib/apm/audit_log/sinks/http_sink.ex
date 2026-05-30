defmodule Apm.AuditLog.Sinks.HttpSink do
  @moduledoc """
  HTTP audit sink — fires a POST request to a configurable SIEM/audit endpoint.

  ## Configuration

      config :apm, Apm.AuditLog.Sinks.HttpSink,
        endpoint_url: "https://siem.example/audit",
        timeout_ms: 500,
        max_retries: 0

  | Key            | Default                         | Description                                   |
  |----------------|---------------------------------|-----------------------------------------------|
  | `endpoint_url` | `"https://siem.example/audit"`  | Full URL to POST audit events to              |
  | `timeout_ms`   | `500`                           | Connect + response timeout in milliseconds    |
  | `max_retries`  | `0`                             | Retry attempts on failure (0 = no retry)      |

  ## Behaviour

  * Encodes the event map as JSON via `Jason.encode!/1`.
  * Uses Erlang's built-in `:httpc` (no additional dependency needed) for the
    HTTP POST.
  * On failure the sink logs a `Logger.warning/1` and returns `{:error, reason}`
    — it NEVER raises, so `AuditLog` GenServer is never blocked.
  * `max_retries: 0` is the default (and recommended for audit sinks) to keep
    latency bounded and avoid PII/sensitive data being held in retry queues.

  ## Integration with AuditLog

  This module implements `Apm.AuditLog.Sink` and is invoked from
  `AuditLog.dispatch_sinks/1` inside a `Task.start/1` (fire-and-forget).
  """

  @behaviour Apm.AuditLog.Sink

  require Logger

  @default_endpoint "https://siem.example/audit"
  @default_timeout_ms 500
  @default_max_retries 0

  @impl true
  @spec push_event(map()) :: :ok | {:error, term()}
  def push_event(event) do
    cfg = config()
    url = Keyword.get(cfg, :endpoint_url, @default_endpoint)
    timeout_ms = Keyword.get(cfg, :timeout_ms, @default_timeout_ms)
    max_retries = Keyword.get(cfg, :max_retries, @default_max_retries)

    do_post(event, url, timeout_ms, max_retries)
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp do_post(event, url, timeout_ms, retries_left) do
    body = Jason.encode!(event)
    url_charlist = to_charlist(url)
    headers = [{"content-type", "application/json"}, {"user-agent", "ccem-apm-audit-sink/1.0"}]

    # :httpc requires charlist headers
    httpc_headers =
      Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    request = {url_charlist, httpc_headers, ~c"application/json", body}
    http_opts = [timeout: timeout_ms, connect_timeout: timeout_ms]

    # Start :inets application if not already running (no-op in Phoenix apps
    # where it's always started, but safe in test/standalone contexts).
    _ = :inets.start()
    _ = :ssl.start()

    case :httpc.request(:post, request, http_opts, []) do
      {:ok, {{_version, status, _phrase}, _resp_headers, _body}}
      when status >= 200 and status < 300 ->
        :ok

      {:ok, {{_version, status, phrase}, _resp_headers, _body}} ->
        reason = {:http_error, status, to_string(phrase)}

        if retries_left > 0 do
          Logger.warning(
            "[AuditLog.HttpSink] HTTP #{status} from #{url}, retrying (#{retries_left} left)"
          )

          do_post(event, url, timeout_ms, retries_left - 1)
        else
          Logger.warning(
            "[AuditLog.HttpSink] HTTP #{status} from #{url}: #{inspect(reason)} — dropping event #{Map.get(event, :event_id, "?")}"
          )

          {:error, reason}
        end

      {:error, reason} ->
        if retries_left > 0 do
          Logger.warning(
            "[AuditLog.HttpSink] Request to #{url} failed: #{inspect(reason)}, retrying (#{retries_left} left)"
          )

          do_post(event, url, timeout_ms, retries_left - 1)
        else
          Logger.warning(
            "[AuditLog.HttpSink] Request to #{url} failed: #{inspect(reason)} — dropping event #{Map.get(event, :event_id, "?")}"
          )

          {:error, reason}
        end
    end
  rescue
    e ->
      Logger.warning(
        "[AuditLog.HttpSink] Unexpected error: #{inspect(e)} — dropping event #{Map.get(event, :event_id, "?")}"
      )

      {:error, {:exception, e}}
  end

  defp config do
    Application.get_env(:apm, __MODULE__, [])
  end
end
