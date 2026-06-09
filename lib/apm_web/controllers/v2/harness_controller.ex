defmodule ApmWeb.V2.HarnessController do
  @moduledoc """
  REST API controller for the Claude Code Harness plugin.

  ## Endpoints

  - `GET /api/v2/harness/health`   — HarnessMonitor health check
  - `GET /api/v2/harness/hooks`    — recent hook telemetry events + stats
  - `GET /api/v2/harness/session`  — raw session state from HarnessMonitor
  - `GET /api/v2/harness/plans`    — list plan files under ~/.claude/plans/
  - `GET /api/v2/harness/settings` — sanitized ~/.claude/settings.json keys
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  # api-s7 Wave 1 — minimal annotations injected by /tmp/api-s7/annotate.py.
  # CastAndValidate is permissive: replace_params: false, freeform 200 schemas.
  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: ApmWeb.Plugs.OpenApiErrorRenderer

  alias Apm.Plugins.Harness.HarnessMonitor
  alias Apm.Plugins.Harness.HookTelemetryBuffer

  @max_hook_limit 200
  @default_hook_limit 50
  @plans_dir "~/.claude/plans"
  @settings_path "~/.claude/settings.json"

  # ── GET /api/v2/harness/health ────────────────────────────────────────────

  @doc "Health check for the HarnessMonitor GenServer."
  @spec health(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation(:health,
    summary: "Health check",
    tags: ["Harness"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def health(conn, _params) do
    case safe_call(fn -> HarnessMonitor.health_check() end) do
      {:ok, result} ->
        json(conn, %{data: result})

      {:error, :not_alive} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: %{code: "not_alive", message: "HarnessMonitor is not running"}})
    end
  end

  # ── GET /api/v2/harness/hooks ─────────────────────────────────────────────

  @doc "Recent hook telemetry events with per-event-type stats."
  @spec hooks(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation(:hooks,
    summary: "Hooks",
    tags: ["Harness"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def hooks(conn, params) do
    limit =
      params
      |> Map.get("limit", to_string(@default_hook_limit))
      |> parse_limit()

    case safe_call(fn -> {HookTelemetryBuffer.recent(limit), HookTelemetryBuffer.stats()} end) do
      {:ok, {events, stats}} ->
        json(conn, %{data: %{events: events, stats: stats}})

      {:error, :not_alive} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: %{code: "not_alive", message: "HookTelemetryBuffer is not running"}})
    end
  end

  # ── GET /api/v2/harness/session ───────────────────────────────────────────

  @doc "Raw session state from HarnessMonitor."
  @spec session(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation(:session,
    summary: "Session",
    tags: ["Harness"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def session(conn, _params) do
    case safe_call(fn -> HarnessMonitor.current_state() end) do
      {:ok, state} ->
        json(conn, %{data: state})

      {:error, :not_alive} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: %{code: "not_alive", message: "HarnessMonitor is not running"}})
    end
  end

  # ── GET /api/v2/harness/plans ─────────────────────────────────────────────

  @doc "List plan files under ~/.claude/plans/."
  @spec plans(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation(:plans,
    summary: "Plans",
    tags: ["Harness"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def plans(conn, _params) do
    plans_dir = Path.expand(@plans_dir)

    files =
      case File.ls(plans_dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&String.ends_with?(&1, [".md", ".json", ".txt"]))
          |> Enum.sort()

        {:error, _} ->
          []
      end

    json(conn, %{data: %{plans: files, count: length(files)}})
  end

  # ── GET /api/v2/harness/settings ─────────────────────────────────────────

  @doc "Sanitized settings.json keys and hook count (env values stripped)."
  @spec settings(Plug.Conn.t(), map()) :: Plug.Conn.t()
  operation(:settings,
    summary: "Settings",
    tags: ["Harness"],
    responses: [
      ok: {"OK", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def settings(conn, _params) do
    settings_path = Path.expand(@settings_path)

    case File.read(settings_path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, decoded} ->
            keys = Map.keys(decoded)
            hook_count = decoded |> Map.get("hooks", %{}) |> count_hooks()
            sanitized = sanitize_settings(decoded)

            json(conn, %{
              data: %{
                keys: keys,
                hook_count: hook_count,
                settings: sanitized
              }
            })

          {:error, _} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: %{code: "parse_error", message: "settings.json is not valid JSON"}})
        end

      {:error, :enoent} ->
        json(conn, %{data: %{keys: [], hook_count: 0, settings: %{}}})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: %{code: "read_error", message: inspect(reason)}})
    end
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec safe_call((-> any())) :: {:ok, any()} | {:error, :not_alive}
  defp safe_call(fun) do
    {:ok, fun.()}
  rescue
    _ -> {:error, :not_alive}
  catch
    :exit, _ -> {:error, :not_alive}
  end

  @spec parse_limit(binary() | integer()) :: pos_integer()
  defp parse_limit(val) when is_integer(val), do: min(val, @max_hook_limit)

  defp parse_limit(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n > 0 -> min(n, @max_hook_limit)
      _ -> @default_hook_limit
    end
  end

  defp parse_limit(_), do: @default_hook_limit

  @spec count_hooks(map() | list() | any()) :: non_neg_integer()
  defp count_hooks(hooks) when is_map(hooks) do
    hooks
    |> Map.values()
    |> Enum.flat_map(fn v -> if is_list(v), do: v, else: [] end)
    |> length()
  end

  defp count_hooks(hooks) when is_list(hooks), do: length(hooks)
  defp count_hooks(_), do: 0

  # Strip env-style values: any value that looks like a secret or env var reference.
  @spec sanitize_settings(map()) :: map()
  defp sanitize_settings(settings) when is_map(settings) do
    Map.new(settings, fn {k, v} -> {k, sanitize_value(k, v)} end)
  end

  defp sanitize_value(key, value) when is_binary(value) do
    key_str = to_string(key)

    if secret_key?(key_str) do
      "[REDACTED]"
    else
      value
    end
  end

  defp sanitize_value(_key, value) when is_map(value), do: sanitize_settings(value)
  defp sanitize_value(_key, value), do: value

  defp secret_key?(key) do
    lower = String.downcase(key)

    String.contains?(lower, ["secret", "password", "token", "key", "credential", "api_key"]) or
      String.match?(lower, ~r/^[A-Z0-9_]{5,}$/)
  end
end
