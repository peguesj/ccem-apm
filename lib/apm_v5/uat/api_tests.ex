defmodule ApmV5.Uat.ApiTests do
  @moduledoc """
  UAT test suite for CCEM APM API endpoints.

  Exercises all Core API (/api) and V2 API (/api/v2) endpoints against
  the running APM server at localhost:3032.  GET endpoints assert 200;
  POST endpoints assert not-500.
  """

  @behaviour ApmV5.Uat.TestSuite

  # --- Behaviour Callbacks ---

  @impl true
  def category, do: :api

  @impl true
  def count, do: length(tests())

  @impl true
  def run, do: Enum.map(tests(), &execute_test/1)

  # --- Test Catalog ---

  defp tests do
    [
      # Core API GET
      %{id: "API-001", name: "GET /api/status", method: :get, path: "/api/status", payload: nil},
      %{id: "API-002", name: "GET /api/agents", method: :get, path: "/api/agents", payload: nil},
      %{id: "API-003", name: "GET /api/data", method: :get, path: "/api/data", payload: nil},
      %{id: "API-004", name: "GET /api/notifications", method: :get, path: "/api/notifications", payload: nil},
      %{id: "API-005", name: "GET /api/ralph", method: :get, path: "/api/ralph", payload: nil},
      %{id: "API-006", name: "GET /api/ralph/flowchart", method: :get, path: "/api/ralph/flowchart", payload: nil},
      %{id: "API-007", name: "GET /api/commands", method: :get, path: "/api/commands", payload: nil},
      %{id: "API-008", name: "GET /api/agents/discover", method: :get, path: "/api/agents/discover", payload: nil},
      %{id: "API-009", name: "GET /api/input/pending", method: :get, path: "/api/input/pending", payload: nil},
      %{id: "API-010", name: "GET /api/skills", method: :get, path: "/api/skills", payload: nil},
      %{id: "API-011", name: "GET /api/skills/registry", method: :get, path: "/api/skills/registry", payload: nil},
      %{id: "API-012", name: "GET /api/projects", method: :get, path: "/api/projects", payload: nil},
      %{id: "API-013", name: "GET /api/ports", method: :get, path: "/api/ports", payload: nil},
      %{id: "API-014", name: "GET /api/ports/clashes", method: :get, path: "/api/ports/clashes", payload: nil},
      %{id: "API-015", name: "GET /api/environments", method: :get, path: "/api/environments", payload: nil},
      %{id: "API-016", name: "GET /api/bg-tasks", method: :get, path: "/api/bg-tasks", payload: nil},
      %{id: "API-017", name: "GET /api/tasks", method: :get, path: "/api/tasks", payload: nil},
      %{id: "API-018", name: "GET /api/scanner/results", method: :get, path: "/api/scanner/results", payload: nil},
      %{id: "API-019", name: "GET /api/scanner/status", method: :get, path: "/api/scanner/status", payload: nil},
      %{id: "API-020", name: "GET /api/actions", method: :get, path: "/api/actions", payload: nil},
      %{id: "API-021", name: "GET /api/actions/runs", method: :get, path: "/api/actions/runs", payload: nil},
      %{id: "API-022", name: "GET /api/telemetry", method: :get, path: "/api/telemetry", payload: nil},
      %{id: "API-023", name: "GET /api/intake", method: :get, path: "/api/intake", payload: nil},
      %{id: "API-024", name: "GET /api/intake/watchers", method: :get, path: "/api/intake/watchers", payload: nil},
      %{id: "API-025", name: "GET /api/openapi.json", method: :get, path: "/api/openapi.json", payload: nil},
      # Core API POST
      %{id: "API-026", name: "POST /api/register", method: :post, path: "/api/register", payload: %{"agent_id" => "uat-api-001", "status" => "active"}},
      %{id: "API-027", name: "POST /api/heartbeat", method: :post, path: "/api/heartbeat", payload: %{"agent_id" => "uat-api-001"}},
      %{id: "API-028", name: "POST /api/notify", method: :post, path: "/api/notify", payload: %{"title" => "UAT", "message" => "test", "type" => "info"}},
      %{id: "API-029", name: "POST /api/config/reload", method: :post, path: "/api/config/reload", payload: %{}},
      # V2 API GET
      %{id: "API-030", name: "GET /api/v2/agents", method: :get, path: "/api/v2/agents", payload: nil},
      %{id: "API-031", name: "GET /api/v2/sessions", method: :get, path: "/api/v2/sessions", payload: nil},
      %{id: "API-032", name: "GET /api/v2/metrics", method: :get, path: "/api/v2/metrics", payload: nil},
      %{id: "API-033", name: "GET /api/v2/slos", method: :get, path: "/api/v2/slos", payload: nil},
      %{id: "API-034", name: "GET /api/v2/alerts", method: :get, path: "/api/v2/alerts", payload: nil},
      %{id: "API-035", name: "GET /api/v2/alerts/rules", method: :get, path: "/api/v2/alerts/rules", payload: nil},
      %{id: "API-036", name: "GET /api/v2/audit", method: :get, path: "/api/v2/audit", payload: nil},
      %{id: "API-037", name: "GET /api/v2/openapi.json", method: :get, path: "/api/v2/openapi.json", payload: nil},
      %{id: "API-038", name: "GET /api/v2/workflows", method: :get, path: "/api/v2/workflows", payload: nil},
      %{id: "API-039", name: "GET /api/v2/formations", method: :get, path: "/api/v2/formations", payload: nil},
      %{id: "API-040", name: "GET /api/v2/ag-ui/router/stats", method: :get, path: "/api/v2/ag-ui/router/stats", payload: nil},
      %{id: "API-041", name: "GET /api/v2/export", method: :get, path: "/api/v2/export", payload: nil},
      # V2 API POST
      %{id: "API-042", name: "POST /api/v2/ag-ui/emit", method: :post, path: "/api/v2/ag-ui/emit", payload: %{"type" => "CUSTOM", "data" => %{"name" => "uat"}}},
      %{id: "API-043", name: "POST /api/v2/verify/double", method: :post, path: "/api/v2/verify/double", payload: %{"target" => "test", "checks" => ["compile"]}}
    ]
  end

  # --- Test Execution ---

  defp execute_test(test) do
    start = System.monotonic_time(:millisecond)

    try do
      {status_code, message} = make_request(test.method, test.path, test.payload)
      elapsed = System.monotonic_time(:millisecond) - start

      result_status = evaluate_status(test.method, status_code)

      %{
        id: test.id,
        category: :api,
        name: test.name,
        status: result_status,
        duration_ms: elapsed,
        message: message,
        tested_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    rescue
      e ->
        elapsed = System.monotonic_time(:millisecond) - start

        %{
          id: test.id,
          category: :api,
          name: test.name,
          status: :fail,
          duration_ms: elapsed,
          message: "Exception: #{Exception.message(e)}",
          tested_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
    end
  end

  defp make_request(:get, path, _payload), do: http_get(path)
  defp make_request(:post, path, payload), do: http_post(path, payload)

  defp evaluate_status(:get, status_code) when is_integer(status_code) do
    if status_code == 200, do: :pass, else: :fail
  end

  defp evaluate_status(:post, status_code) when is_integer(status_code) do
    if status_code < 500, do: :pass, else: :fail
  end

  defp evaluate_status(_method, _status_code), do: :fail

  # --- HTTP Helpers ---

  defp http_get(path) do
    url = ~c"http://localhost:3032#{path}"

    case :httpc.request(:get, {url, [~c"accept: application/json"]}, [timeout: 5000, connect_timeout: 3000], []) do
      {:ok, {{_, status, reason}, _headers, _body}} ->
        {status, "#{status} #{reason}"}

      {:error, reason} ->
        {:error, "Connection error: #{inspect(reason)}"}
    end
  end

  defp http_post(path, body_map) do
    url = ~c"http://localhost:3032#{path}"
    body = Jason.encode!(body_map)

    case :httpc.request(:post, {url, [~c"accept: application/json"], ~c"application/json", body}, [timeout: 5000, connect_timeout: 3000], []) do
      {:ok, {{_, status, reason}, _headers, _body}} ->
        {status, "#{status} #{reason}"}

      {:error, reason} ->
        {:error, "Connection error: #{inspect(reason)}"}
    end
  end
end
