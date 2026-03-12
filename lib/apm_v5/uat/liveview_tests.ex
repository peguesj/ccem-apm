defmodule ApmV5.Uat.LiveViewTests do
  @moduledoc """
  UAT test suite for LiveView page accessibility.

  GETs each LiveView path via `:httpc` and asserts a 200 status
  with an expected marker string present in the response body
  (case-insensitive).
  """

  @behaviour ApmV5.Uat.TestSuite

  @impl true
  def category, do: :liveview

  @impl true
  def count, do: length(test_definitions())

  @impl true
  def run do
    ensure_httpc_started()
    Enum.map(test_definitions(), &execute_test/1)
  end

  # --- Test Definitions ---

  @spec test_definitions() :: [map()]
  defp test_definitions do
    [
      %{id: "LV-001", path: "/", markers: ["Dashboard", "CCEM"], name: "Dashboard root page"},
      %{id: "LV-002", path: "/apm-all", markers: ["Projects"], name: "All projects page"},
      %{id: "LV-003", path: "/ralph", markers: ["Ralph"], name: "Ralph page"},
      %{id: "LV-004", path: "/skills", markers: ["Skills"], name: "Skills page"},
      %{id: "LV-005", path: "/timeline", markers: ["Timeline"], name: "Timeline page"},
      %{id: "LV-006", path: "/docs", markers: ["Documentation", "Docs"], name: "Docs page"},
      %{id: "LV-007", path: "/formation", markers: ["Formation"], name: "Formation page"},
      %{id: "LV-008", path: "/notifications", markers: ["Notification"], name: "Notifications page"},
      %{id: "LV-009", path: "/ports", markers: ["Port"], name: "Ports page"},
      %{id: "LV-010", path: "/tasks", markers: ["Task"], name: "Tasks page"},
      %{id: "LV-011", path: "/scanner", markers: ["Scanner", "Project"], name: "Scanner page"},
      %{id: "LV-012", path: "/actions", markers: ["Action"], name: "Actions page"},
      %{id: "LV-013", path: "/analytics", markers: ["Analytics"], name: "Analytics page"},
      %{id: "LV-014", path: "/health", markers: ["Health"], name: "Health page"},
      %{id: "LV-015", path: "/conversations", markers: ["Conversation"], name: "Conversations page"},
      %{id: "LV-016", path: "/plugins", markers: ["Plugin"], name: "Plugins page"},
      %{id: "LV-017", path: "/backfill", markers: ["Backfill"], name: "Backfill page"},
      %{id: "LV-018", path: "/drtw", markers: ["DRTW"], name: "DRTW page"},
      %{id: "LV-019", path: "/intake", markers: ["Intake"], name: "Intake page"},
      %{id: "LV-020", path: "/workflow/ship", markers: ["Workflow", "Ship"], name: "Workflow ship page"}
    ]
  end

  # --- Test Execution ---

  defp execute_test(test_def) do
    started_at = System.monotonic_time(:millisecond)

    try do
      case http_get(test_def.path) do
        {200, body} ->
          duration = System.monotonic_time(:millisecond) - started_at
          lower_body = String.downcase(body)

          if Enum.any?(test_def.markers, &String.contains?(lower_body, String.downcase(&1))) do
            build_result(test_def, :passed, duration, "200 OK — marker found")
          else
            markers_str = Enum.join(test_def.markers, " | ")

            build_result(
              test_def,
              :failed,
              duration,
              "200 OK but no marker matched (expected: #{markers_str})"
            )
          end

        {status, _body} ->
          duration = System.monotonic_time(:millisecond) - started_at
          build_result(test_def, :failed, duration, "HTTP #{status} (expected 200)")

        {:error, reason} ->
          duration = System.monotonic_time(:millisecond) - started_at
          build_result(test_def, :failed, duration, "HTTP error: #{inspect(reason)}")
      end
    rescue
      e ->
        duration = System.monotonic_time(:millisecond) - started_at
        build_result(test_def, :failed, duration, "Exception: #{Exception.message(e)}")
    end
  end

  # --- HTTP Helper ---

  defp http_get(path) do
    url = ~c"http://localhost:3032#{path}"

    case :httpc.request(:get, {url, []}, [timeout: 10_000, connect_timeout: 3_000], []) do
      {:ok, {{_, status, _}, _headers, body}} -> {status, to_string(body)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_httpc_started do
    case :inets.start() do
      :ok -> :ok
      {:error, {:already_started, :inets}} -> :ok
    end
  end

  # --- Result Builder ---

  defp build_result(test_def, status, duration_ms, message) do
    %{
      id: test_def.id,
      category: :liveview,
      name: test_def.name,
      status: status,
      duration_ms: duration_ms,
      message: message,
      tested_at: DateTime.utc_now()
    }
  end
end
