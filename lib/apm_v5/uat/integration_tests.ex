defmodule ApmV5.Uat.IntegrationTests do
  @moduledoc """
  UAT test suite for end-to-end integration flows.

  Exercises multi-step API workflows (agent lifecycle, heartbeat updates,
  notification flow, config reload, formation create-list) against the
  running APM server at localhost:3032.
  """

  @behaviour ApmV5.Uat.TestSuite

  # --- Behaviour Callbacks ---

  @impl true
  def category, do: :integration

  @impl true
  def count, do: 5

  @impl true
  def run do
    [
      run_test("INT-001", "Agent lifecycle", &test_agent_lifecycle/0),
      run_test("INT-002", "Heartbeat updates", &test_heartbeat_updates/0),
      run_test("INT-003", "Notification flow", &test_notification_flow/0),
      run_test("INT-004", "Config reload", &test_config_reload/0),
      run_test("INT-005", "Formation create-list", &test_formation_create_list/0)
    ]
  end

  # --- Test Implementations ---

  defp test_agent_lifecycle do
    {post_status, _} = http_post("/api/register", %{"agent_id" => "uat-int-001", "status" => "active"})

    if not is_integer(post_status) or post_status >= 500 do
      {:fail, "POST /api/register failed with #{inspect(post_status)}"}
    else
      {get_status, body} = http_get("/api/agents")

      cond do
        not is_integer(get_status) ->
          {:fail, "GET /api/agents connection error: #{inspect(get_status)}"}

        get_status != 200 ->
          {:fail, "GET /api/agents returned #{get_status}"}

        String.contains?(body, "uat-int-001") ->
          {:pass, "Agent uat-int-001 registered and found in agent list"}

        true ->
          {:fail, "Agent uat-int-001 not found in response body"}
      end
    end
  end

  defp test_heartbeat_updates do
    {status, body} = http_post("/api/heartbeat", %{"agent_id" => "uat-int-001"})

    if is_integer(status) and status == 200 do
      {:pass, "Heartbeat accepted: 200"}
    else
      {:fail, "Heartbeat failed: #{inspect(status)} #{body}"}
    end
  end

  defp test_notification_flow do
    {post_status, _} =
      http_post("/api/notify", %{
        "title" => "UAT INT Test",
        "message" => "integration",
        "type" => "info"
      })

    if not is_integer(post_status) or post_status >= 500 do
      {:fail, "POST /api/notify failed with #{inspect(post_status)}"}
    else
      {get_status, body} = http_get("/api/notifications")

      cond do
        not is_integer(get_status) ->
          {:fail, "GET /api/notifications connection error: #{inspect(get_status)}"}

        get_status != 200 ->
          {:fail, "GET /api/notifications returned #{get_status}"}

        String.contains?(body, "UAT INT Test") ->
          {:pass, "Notification created and found in list"}

        true ->
          {:fail, "Notification 'UAT INT Test' not found in response body"}
      end
    end
  end

  defp test_config_reload do
    {status, body} = http_post("/api/config/reload", %{})

    if is_integer(status) and status == 200 do
      {:pass, "Config reload accepted: 200"}
    else
      {:fail, "Config reload failed: #{inspect(status)} #{body}"}
    end
  end

  defp test_formation_create_list do
    {post_status, _} =
      http_post("/api/v2/formations", %{
        "formation_id" => "uat-fmt-001",
        "name" => "UAT Test Formation",
        "status" => "active"
      })

    if not is_integer(post_status) or post_status >= 500 do
      {:fail, "POST /api/v2/formations failed with #{inspect(post_status)}"}
    else
      {get_status, body} = http_get("/api/v2/formations")

      cond do
        not is_integer(get_status) ->
          {:fail, "GET /api/v2/formations connection error: #{inspect(get_status)}"}

        get_status != 200 ->
          {:fail, "GET /api/v2/formations returned #{get_status}"}

        String.contains?(body, "uat-fmt-001") ->
          {:pass, "Formation uat-fmt-001 created and found in list"}

        true ->
          {:fail, "Formation uat-fmt-001 not found in response body"}
      end
    end
  end

  # --- Test Runner ---

  defp run_test(id, name, test_fn) do
    start = System.monotonic_time(:millisecond)

    try do
      {status, message} = test_fn.()
      elapsed = System.monotonic_time(:millisecond) - start

      %{
        id: id,
        category: :integration,
        name: name,
        status: status,
        duration_ms: elapsed,
        message: message,
        tested_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    rescue
      e ->
        elapsed = System.monotonic_time(:millisecond) - start

        %{
          id: id,
          category: :integration,
          name: name,
          status: :fail,
          duration_ms: elapsed,
          message: "Exception: #{Exception.message(e)}",
          tested_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
    end
  end

  # --- HTTP Helpers ---

  defp http_get(path) do
    url = ~c"http://localhost:3032#{path}"

    case :httpc.request(:get, {url, [~c"accept: application/json"]}, [timeout: 5000, connect_timeout: 3000], []) do
      {:ok, {{_, status, _}, _headers, body}} -> {status, to_string(body)}
      {:error, reason} -> {:error, "Connection error: #{inspect(reason)}"}
    end
  end

  defp http_post(path, body_map) do
    url = ~c"http://localhost:3032#{path}"
    body = Jason.encode!(body_map)

    case :httpc.request(:post, {url, [~c"accept: application/json"], ~c"application/json", body}, [timeout: 5000, connect_timeout: 3000], []) do
      {:ok, {{_, status, _}, _headers, resp}} -> {status, to_string(resp)}
      {:error, reason} -> {:error, "Connection error: #{inspect(reason)}"}
    end
  end
end
