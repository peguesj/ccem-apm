defmodule ApmV5.Uat.AgUiTests do
  @moduledoc """
  UAT test suite for AG-UI protocol integration.

  Exercises AG-UI subsystems: EventRouter stats, StateManager round-trip,
  SSE endpoint availability, and EventStream module presence.
  """

  @behaviour ApmV5.Uat.TestSuite

  # --- Behaviour Callbacks ---

  @impl true
  def category, do: :agui

  @impl true
  def count, do: 4

  @impl true
  def run do
    [
      run_test("AG-001", "EventRouter stats", &test_event_router_stats/0),
      run_test("AG-002", "StateManager round-trip", &test_state_manager_round_trip/0),
      run_test("AG-003", "SSE endpoint content-type", &test_sse_endpoint/0),
      run_test("AG-004", "EventStream module loaded", &test_event_stream_loaded/0)
    ]
  end

  # --- Test Implementations ---

  defp test_event_router_stats do
    stats = ApmV5.AgUi.EventRouter.stats()

    if is_map(stats) and Map.has_key?(stats, :routed_count) do
      {:pass, "EventRouter.stats() returned map with :routed_count = #{stats.routed_count}"}
    else
      {:fail, "Expected map with :routed_count, got: #{inspect(stats)}"}
    end
  end

  defp test_state_manager_round_trip do
    mod = ApmV5.AgUi.StateManager
    agent_id = "uat-agent"

    set_exists = function_exported?(mod, :set_state, 2)
    get_exists = function_exported?(mod, :get_state, 1)

    unless set_exists and get_exists do
      throw(:skip)
    end

    try do
      :ok = mod.set_state(agent_id, %{x: 1})
      state = mod.get_state(agent_id)

      result =
        if is_map(state) and Map.get(state, :x) == 1 do
          {:pass, "Round-trip OK: set %{x: 1}, got #{inspect(state)}"}
        else
          {:fail, "Expected state with x: 1, got: #{inspect(state)}"}
        end

      result
    after
      # Clean up — use remove_state if available, otherwise best-effort
      if function_exported?(mod, :remove_state, 1) do
        mod.remove_state(agent_id)
      end
    end
  end

  defp test_sse_endpoint do
    url = ~c"http://localhost:3032/api/v2/ag-ui/events"

    case :httpc.request(:get, {url, [~c"accept: text/event-stream"]}, [timeout: 5000, connect_timeout: 3000], []) do
      {:ok, {{_, 200, _}, _headers, _body}} ->
        {:pass, "SSE endpoint returned 200"}

      {:ok, {{_, status, reason}, _headers, _body}} ->
        {:fail, "SSE endpoint returned #{status} #{reason}"}

      {:error, reason} ->
        {:fail, "Connection error: #{inspect(reason)}"}
    end
  end

  defp test_event_stream_loaded do
    mod = ApmV5.EventStream

    if Code.ensure_loaded?(mod) and function_exported?(mod, :emit, 2) do
      {:pass, "ApmV5.EventStream loaded, emit/2 exported"}
    else
      {:fail, "ApmV5.EventStream not loaded or emit/2 not exported"}
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
        category: :agui,
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
          category: :agui,
          name: name,
          status: :fail,
          duration_ms: elapsed,
          message: "Exception: #{Exception.message(e)}",
          tested_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
    catch
      :throw, :skip ->
        elapsed = System.monotonic_time(:millisecond) - start

        %{
          id: id,
          category: :agui,
          name: name,
          status: :skip,
          duration_ms: elapsed,
          message: "Required functions not exported; skipped",
          tested_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
    end
  end
end
