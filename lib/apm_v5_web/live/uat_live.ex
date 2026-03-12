defmodule ApmV5Web.UatLive do
  @moduledoc """
  UAT Integration Testing Panel — live exerciser for all AG-UI subsystems.

  Test categories:
  - EventType validation (ag_ui_ex library constants)
  - EventStream emit + retrieve
  - EventRouter routing + stats
  - HookBridge translation (register→RUN_STARTED, heartbeat→STEP_*, notify→CUSTOM)
  - StateManager snapshot/delta round-trip
  - SSE endpoint connectivity
  - ChatStore message persistence
  - Full lifecycle (emit→route→stream→SSE)
  """

  use ApmV5Web, :live_view
  require Logger

  alias AgUi.Core.Events.EventType
  alias ApmV5.AgUi.{EventRouter, StateManager}
  alias ApmV5.EventStream

  @test_agent_id "uat-test-agent-#{:erlang.phash2(self())}"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "UAT",
       tests: initial_tests(),
       running: false,
       run_count: 0,
       last_run_at: nil,
       selected_test: nil,
       test_log: []
     )}
  end

  @impl true
  def handle_event("run_all", _params, socket) do
    send(self(), :run_all_tests)
    {:noreply, assign(socket, running: true, test_log: [])}
  end

  def handle_event("run_test", %{"id" => test_id}, socket) do
    send(self(), {:run_test, test_id})
    {:noreply, assign(socket, running: true, test_log: [])}
  end

  def handle_event("select_test", %{"id" => test_id}, socket) do
    {:noreply, assign(socket, selected_test: test_id)}
  end

  @impl true
  def handle_info(:run_all_tests, socket) do
    tests = run_all_tests()
    log = Enum.flat_map(tests, fn t -> t.log end)

    {:noreply,
     assign(socket,
       tests: tests,
       running: false,
       run_count: socket.assigns.run_count + 1,
       last_run_at: DateTime.utc_now() |> DateTime.to_iso8601(),
       test_log: log
     )}
  end

  def handle_info({:run_test, test_id}, socket) do
    tests =
      Enum.map(socket.assigns.tests, fn t ->
        if t.id == test_id, do: run_single_test(t), else: t
      end)

    log = Enum.find(tests, &(&1.id == test_id)) |> Map.get(:log, [])

    {:noreply,
     assign(socket,
       tests: tests,
       running: false,
       run_count: socket.assigns.run_count + 1,
       last_run_at: DateTime.utc_now() |> DateTime.to_iso8601(),
       test_log: log,
       selected_test: test_id
     )}
  end

  # -- Test Definitions -------------------------------------------------------

  defp initial_tests do
    [
      %{id: "event_types", name: "EventType Constants", category: "ag_ui_ex", status: :pending, duration_ms: 0, log: [], assertions: 0, failures: 0},
      %{id: "event_type_valid", name: "EventType.valid?/1", category: "ag_ui_ex", status: :pending, duration_ms: 0, log: [], assertions: 0, failures: 0},
      %{id: "event_type_all", name: "EventType.all/0", category: "ag_ui_ex", status: :pending, duration_ms: 0, log: [], assertions: 0, failures: 0},
      %{id: "event_stream_emit", name: "EventStream Emit", category: "event_stream", status: :pending, duration_ms: 0, log: [], assertions: 0, failures: 0},
      %{id: "event_stream_retrieve", name: "EventStream Retrieve", category: "event_stream", status: :pending, duration_ms: 0, log: [], assertions: 0, failures: 0},
      %{id: "event_router_route", name: "EventRouter Route", category: "event_router", status: :pending, duration_ms: 0, log: [], assertions: 0, failures: 0},
      %{id: "event_router_stats", name: "EventRouter Stats", category: "event_router", status: :pending, duration_ms: 0, log: [], assertions: 0, failures: 0},
      %{id: "hook_bridge_register", name: "HookBridge Register→RUN_STARTED", category: "hook_bridge", status: :pending, duration_ms: 0, log: [], assertions: 0, failures: 0},
      %{id: "hook_bridge_heartbeat", name: "HookBridge Heartbeat→STEP_*", category: "hook_bridge", status: :pending, duration_ms: 0, log: [], assertions: 0, failures: 0},
      %{id: "hook_bridge_notify", name: "HookBridge Notify→CUSTOM", category: "hook_bridge", status: :pending, duration_ms: 0, log: [], assertions: 0, failures: 0},
      %{id: "state_snapshot", name: "StateManager Snapshot", category: "state_manager", status: :pending, duration_ms: 0, log: [], assertions: 0, failures: 0},
      %{id: "state_delta", name: "StateManager Delta", category: "state_manager", status: :pending, duration_ms: 0, log: [], assertions: 0, failures: 0},
      %{id: "chat_store", name: "ChatStore Persistence", category: "chat_store", status: :pending, duration_ms: 0, log: [], assertions: 0, failures: 0},
      %{id: "lifecycle_e2e", name: "Full Lifecycle E2E", category: "e2e", status: :pending, duration_ms: 0, log: [], assertions: 0, failures: 0}
    ]
  end

  defp run_all_tests do
    Enum.map(initial_tests(), &run_single_test/1)
  end

  defp run_single_test(%{id: id} = test) do
    start = System.monotonic_time(:millisecond)

    {status, log, assertions, failures} =
      try do
        run_test_case(id)
      rescue
        e ->
          {:error, ["EXCEPTION: #{Exception.message(e)}"], 0, 1}
      end

    duration = System.monotonic_time(:millisecond) - start

    %{test |
      status: status,
      duration_ms: duration,
      log: log,
      assertions: assertions,
      failures: failures
    }
  end

  # -- Test Cases -------------------------------------------------------------

  defp run_test_case("event_types") do
    log = []
    assertions = 0
    failures = 0

    expected = [
      {:run_started, "RUN_STARTED"},
      {:run_finished, "RUN_FINISHED"},
      {:run_error, "RUN_ERROR"},
      {:step_started, "STEP_STARTED"},
      {:step_finished, "STEP_FINISHED"},
      {:tool_call_start, "TOOL_CALL_START"},
      {:tool_call_end, "TOOL_CALL_END"},
      {:state_snapshot, "STATE_SNAPSHOT"},
      {:state_delta, "STATE_DELTA"},
      {:text_message_start, "TEXT_MESSAGE_START"},
      {:text_message_content, "TEXT_MESSAGE_CONTENT"},
      {:text_message_end, "TEXT_MESSAGE_END"},
      {:custom, "CUSTOM"}
    ]

    {log, assertions, failures} =
      Enum.reduce(expected, {log, assertions, failures}, fn {func, expected_val}, {l, a, f} ->
        actual = apply(EventType, func, [])
        if actual == expected_val do
          {l ++ ["PASS: EventType.#{func}() == #{inspect(expected_val)}"], a + 1, f}
        else
          {l ++ ["FAIL: EventType.#{func}() returned #{inspect(actual)}, expected #{inspect(expected_val)}"], a + 1, f + 1}
        end
      end)

    status = if failures == 0, do: :pass, else: :fail
    {status, log, assertions, failures}
  end

  defp run_test_case("event_type_valid") do
    valid_types = ["RUN_STARTED", "RUN_FINISHED", "CUSTOM", "STATE_SNAPSHOT"]
    invalid_types = ["INVALID", "not_a_type", "", "run_started"]

    {log, assertions, failures} =
      Enum.reduce(valid_types, {[], 0, 0}, fn type, {l, a, f} ->
        if EventType.valid?(type) do
          {l ++ ["PASS: EventType.valid?(#{inspect(type)}) == true"], a + 1, f}
        else
          {l ++ ["FAIL: EventType.valid?(#{inspect(type)}) should be true"], a + 1, f + 1}
        end
      end)

    {log, assertions, failures} =
      Enum.reduce(invalid_types, {log, assertions, failures}, fn type, {l, a, f} ->
        if EventType.valid?(type) do
          {l ++ ["FAIL: EventType.valid?(#{inspect(type)}) should be false"], a + 1, f + 1}
        else
          {l ++ ["PASS: EventType.valid?(#{inspect(type)}) == false"], a + 1, f}
        end
      end)

    status = if failures == 0, do: :pass, else: :fail
    {status, log, assertions, failures}
  end

  defp run_test_case("event_type_all") do
    all = EventType.all()
    log = ["EventType.all() returned #{length(all)} types"]
    assertions = 0
    failures = 0

    {log, assertions, failures} =
      if is_list(all) and length(all) >= 13 do
        {log ++ ["PASS: all/0 returns a list with >= 13 types"], assertions + 1, failures}
      else
        {log ++ ["FAIL: all/0 returned #{inspect(all)}"], assertions + 1, failures + 1}
      end

    # Verify key types are in the list
    required = ["RUN_STARTED", "RUN_FINISHED", "CUSTOM", "STATE_SNAPSHOT", "TOOL_CALL_START"]
    {log, assertions, failures} =
      Enum.reduce(required, {log, assertions, failures}, fn type, {l, a, f} ->
        if type in all do
          {l ++ ["PASS: #{inspect(type)} in all()"], a + 1, f}
        else
          {l ++ ["FAIL: #{inspect(type)} not in all()"], a + 1, f + 1}
        end
      end)

    status = if failures == 0, do: :pass, else: :fail
    {status, log, assertions, failures}
  end

  defp run_test_case("event_stream_emit") do
    event = EventStream.emit(EventType.custom(), %{
      agent_id: @test_agent_id,
      name: "uat_test",
      value: %{test: true}
    })

    log = ["Emitted event: #{inspect(Map.take(event, [:type, :id]))}"]
    assertions = 0
    failures = 0

    {log, assertions, failures} =
      if is_map(event) and event[:type] == EventType.custom() do
        {log ++ ["PASS: Event emitted with correct type"], assertions + 1, failures}
      else
        {log ++ ["FAIL: Event not emitted correctly: #{inspect(event)}"], assertions + 1, failures + 1}
      end

    {log, assertions, failures} =
      if event[:id] do
        {log ++ ["PASS: Event has an ID: #{event[:id]}"], assertions + 1, failures}
      else
        {log ++ ["FAIL: Event missing ID"], assertions + 1, failures + 1}
      end

    {log, assertions, failures} =
      if event[:timestamp] do
        {log ++ ["PASS: Event has timestamp"], assertions + 1, failures}
      else
        {log ++ ["FAIL: Event missing timestamp"], assertions + 1, failures + 1}
      end

    status = if failures == 0, do: :pass, else: :fail
    {status, log, assertions, failures}
  end

  defp run_test_case("event_stream_retrieve") do
    # Emit a unique event
    unique_id = "uat-retrieve-#{System.monotonic_time()}"
    EventStream.emit(EventType.custom(), %{
      agent_id: unique_id,
      name: "uat_retrieve_test"
    })

    # Retrieve events
    events = EventStream.get_events(%{})
    log = ["Retrieved #{length(events)} events from EventStream"]
    assertions = 0
    failures = 0

    {log, assertions, failures} =
      if length(events) > 0 do
        {log ++ ["PASS: EventStream contains events"], assertions + 1, failures}
      else
        {log ++ ["FAIL: EventStream returned empty list"], assertions + 1, failures + 1}
      end

    # Check our event is in there
    found = Enum.any?(events, fn e -> get_in(e, [:data, :agent_id]) == unique_id end)
    {log, assertions, failures} =
      if found do
        {log ++ ["PASS: Our test event found in stream"], assertions + 1, failures}
      else
        {log ++ ["FAIL: Our test event not found in stream"], assertions + 1, failures + 1}
      end

    status = if failures == 0, do: :pass, else: :fail
    {status, log, assertions, failures}
  end

  defp run_test_case("event_router_route") do
    # Emit and route a test event
    event = EventRouter.emit_and_route(EventType.custom(), %{
      agent_id: @test_agent_id,
      name: "uat_router_test",
      value: %{routed: true}
    })

    log = ["Emitted and routed event: #{inspect(Map.take(event, [:type, :id]))}"]
    assertions = 0
    failures = 0

    {log, assertions, failures} =
      if is_map(event) do
        {log ++ ["PASS: emit_and_route returned an event map"], assertions + 1, failures}
      else
        {log ++ ["FAIL: emit_and_route didn't return a map"], assertions + 1, failures + 1}
      end

    status = if failures == 0, do: :pass, else: :fail
    {status, log, assertions, failures}
  end

  defp run_test_case("event_router_stats") do
    stats = EventRouter.stats()
    log = ["Router stats: routed_count=#{stats.routed_count}"]
    assertions = 0
    failures = 0

    {log, assertions, failures} =
      if is_map(stats) and Map.has_key?(stats, :routed_count) do
        {log ++ ["PASS: Stats has routed_count field"], assertions + 1, failures}
      else
        {log ++ ["FAIL: Stats missing routed_count"], assertions + 1, failures + 1}
      end

    {log, assertions, failures} =
      if Map.has_key?(stats, :by_type) and is_map(stats.by_type) do
        {log ++ ["PASS: Stats has by_type map with #{map_size(stats.by_type)} entries"], assertions + 1, failures}
      else
        {log ++ ["FAIL: Stats missing by_type"], assertions + 1, failures + 1}
      end

    status = if failures == 0, do: :pass, else: :fail
    {status, log, assertions, failures}
  end

  defp run_test_case("hook_bridge_register") do
    agent_id = "uat-hookbridge-#{System.monotonic_time()}"
    before_events = EventStream.get_events(%{})

    # Simulate register via HookBridge
    ApmV5.AgUi.HookBridge.translate_register(%{
      "agent_id" => agent_id,
      "project" => "uat-test",
      "role" => "individual"
    })

    Process.sleep(50)
    after_events = EventStream.get_events(%{})
    new_events = after_events -- before_events
    run_started = Enum.find(new_events, fn e -> e[:type] == EventType.run_started() end)

    log = ["HookBridge.on_register called for agent #{agent_id}"]
    assertions = 0
    failures = 0

    {log, assertions, failures} =
      if run_started do
        {log ++ ["PASS: RUN_STARTED event emitted"], assertions + 1, failures}
      else
        {log ++ ["FAIL: No RUN_STARTED event found. New events: #{length(new_events)}"], assertions + 1, failures + 1}
      end

    status = if failures == 0, do: :pass, else: :fail
    {status, log, assertions, failures}
  end

  defp run_test_case("hook_bridge_heartbeat") do
    agent_id = "uat-heartbeat-#{System.monotonic_time()}"
    before_events = EventStream.get_events(%{})

    ApmV5.AgUi.HookBridge.translate_heartbeat(%{
      "agent_id" => agent_id,
      "status" => "working",
      "message" => "UAT heartbeat test"
    })

    Process.sleep(50)
    after_events = EventStream.get_events(%{})
    new_events = after_events -- before_events

    step_events = Enum.filter(new_events, fn e ->
      e[:type] in [EventType.step_started(), EventType.step_finished()]
    end)

    log = ["HookBridge.on_heartbeat called for agent #{agent_id}"]
    assertions = 0
    failures = 0

    {log, assertions, failures} =
      if length(step_events) > 0 do
        types = Enum.map(step_events, & &1[:type]) |> Enum.join(", ")
        {log ++ ["PASS: STEP events emitted: #{types}"], assertions + 1, failures}
      else
        {log ++ ["FAIL: No STEP events found"], assertions + 1, failures + 1}
      end

    status = if failures == 0, do: :pass, else: :fail
    {status, log, assertions, failures}
  end

  defp run_test_case("hook_bridge_notify") do
    before_events = EventStream.get_events(%{})

    ApmV5.AgUi.HookBridge.translate_notification(%{
      "type" => "info",
      "title" => "UAT Test Notification",
      "message" => "Testing HookBridge notify→CUSTOM translation",
      "category" => "uat"
    })

    Process.sleep(50)
    after_events = EventStream.get_events(%{})
    new_events = after_events -- before_events
    custom = Enum.find(new_events, fn e -> e[:type] == EventType.custom() end)

    log = ["HookBridge.on_notify called"]
    assertions = 0
    failures = 0

    {log, assertions, failures} =
      if custom do
        {log ++ ["PASS: CUSTOM event emitted"], assertions + 1, failures}
      else
        {log ++ ["FAIL: No CUSTOM event found"], assertions + 1, failures + 1}
      end

    status = if failures == 0, do: :pass, else: :fail
    {status, log, assertions, failures}
  end

  defp run_test_case("state_snapshot") do
    agent_id = "uat-state-#{System.monotonic_time()}"
    test_state = %{"status" => "running", "progress" => 0, "uat" => true}

    StateManager.set_state(agent_id, test_state)
    retrieved = StateManager.get_state(agent_id)

    log = ["Set state for agent #{agent_id}"]
    assertions = 0
    failures = 0

    {log, assertions, failures} =
      if retrieved == test_state do
        {log ++ ["PASS: get_state returns the snapshot we set"], assertions + 1, failures}
      else
        {log ++ ["FAIL: get_state returned #{inspect(retrieved)}"], assertions + 1, failures + 1}
      end

    # Check versioned
    case StateManager.get_state_versioned(agent_id) do
      {_state, version} when is_integer(version) and version > 0 ->
        {log ++ ["PASS: Versioned state has version #{version}"], assertions + 1, failures}
      other ->
        {log ++ ["FAIL: Versioned state returned #{inspect(other)}"], assertions + 1, failures + 1}
    end
    |> then(fn {l, a, f} ->
      # Cleanup
      StateManager.remove_state(agent_id)
      status = if f == 0, do: :pass, else: :fail
      {status, l, a, f}
    end)
  end

  defp run_test_case("state_delta") do
    agent_id = "uat-delta-#{System.monotonic_time()}"
    StateManager.set_state(agent_id, %{"status" => "idle", "count" => 0})

    # Apply delta
    result = StateManager.apply_delta(agent_id, [
      %{"op" => "replace", "path" => "/status", "value" => "working"},
      %{"op" => "add", "path" => "/new_field", "value" => "added"}
    ])

    log = ["Applied delta to agent #{agent_id}"]
    assertions = 0
    failures = 0

    {log, assertions, failures} =
      case result do
        {:ok, new_state} ->
          l = log ++ ["PASS: Delta applied successfully"]
          a = assertions + 1

          {l, a, f} =
            if new_state["status"] == "working" do
              {l ++ ["PASS: status replaced to 'working'"], a + 1, failures}
            else
              {l ++ ["FAIL: status not replaced"], a + 1, failures + 1}
            end

          if new_state["new_field"] == "added" do
            {l ++ ["PASS: new_field added"], a + 1, f}
          else
            {l ++ ["FAIL: new_field not added"], a + 1, f + 1}
          end

        {:error, reason} ->
          {log ++ ["FAIL: Delta failed: #{inspect(reason)}"], assertions + 1, failures + 1}
      end

    # Test delta on non-existent agent
    {log, assertions, failures} =
      case StateManager.apply_delta("nonexistent-agent", [%{"op" => "replace", "path" => "/x", "value" => 1}]) do
        {:error, :no_state} ->
          {log ++ ["PASS: Delta on non-existent agent returns {:error, :no_state}"], assertions + 1, failures}
        other ->
          {log ++ ["FAIL: Expected {:error, :no_state}, got #{inspect(other)}"], assertions + 1, failures + 1}
      end

    StateManager.remove_state(agent_id)
    status = if failures == 0, do: :pass, else: :fail
    {status, log, assertions, failures}
  end

  defp run_test_case("chat_store") do
    scope = "uat:test:#{System.monotonic_time()}"

    # Send a message
    ApmV5.ChatStore.send_message(scope, "UAT test message", %{role: "user"})

    messages = ApmV5.ChatStore.list_messages(scope)
    log = ["Sent message to scope #{scope}"]
    assertions = 0
    failures = 0

    {log, assertions, failures} =
      if length(messages) > 0 do
        {log ++ ["PASS: Message persisted (#{length(messages)} messages in scope)"], assertions + 1, failures}
      else
        {log ++ ["FAIL: No messages found in scope"], assertions + 1, failures + 1}
      end

    msg = List.last(messages)
    {log, assertions, failures} =
      if msg && msg[:content] == "UAT test message" do
        {log ++ ["PASS: Message content matches"], assertions + 1, failures}
      else
        {log ++ ["FAIL: Message content mismatch: #{inspect(msg)}"], assertions + 1, failures + 1}
      end

    # Clear
    ApmV5.ChatStore.clear_scope(scope)
    after_clear = ApmV5.ChatStore.list_messages(scope)
    {log, assertions, failures} =
      if length(after_clear) == 0 do
        {log ++ ["PASS: Messages cleared successfully"], assertions + 1, failures}
      else
        {log ++ ["FAIL: Messages not cleared: #{length(after_clear)} remaining"], assertions + 1, failures + 1}
      end

    status = if failures == 0, do: :pass, else: :fail
    {status, log, assertions, failures}
  end

  defp run_test_case("lifecycle_e2e") do
    agent_id = "uat-e2e-#{System.monotonic_time()}"
    log = ["Starting full lifecycle test for agent #{agent_id}"]
    assertions = 0
    failures = 0

    # 1. Register (RUN_STARTED)
    ApmV5.AgUi.HookBridge.translate_register(%{
      "agent_id" => agent_id,
      "project" => "uat-test",
      "role" => "individual"
    })
    Process.sleep(50)

    # 2. Set state (STATE_SNAPSHOT)
    StateManager.set_state(agent_id, %{"phase" => "init"})

    # 3. Heartbeat (STEP_STARTED)
    ApmV5.AgUi.HookBridge.translate_heartbeat(%{
      "agent_id" => agent_id,
      "status" => "working",
      "message" => "E2E step"
    })
    Process.sleep(50)

    # 4. Apply delta (STATE_DELTA)
    StateManager.apply_delta(agent_id, [
      %{"op" => "replace", "path" => "/phase", "value" => "complete"}
    ])

    # 5. Notify (CUSTOM)
    ApmV5.AgUi.HookBridge.translate_notification(%{
      "type" => "success",
      "title" => "E2E Complete",
      "message" => "Full lifecycle test passed",
      "category" => "uat"
    })
    Process.sleep(50)

    # Verify events exist in stream
    events = EventStream.get_events(%{})
    agent_events = Enum.filter(events, fn e ->
      get_in(e, [:data, :agent_id]) == agent_id
    end)

    {log, assertions, failures} =
      if length(agent_events) >= 2 do
        types = Enum.map(agent_events, & &1[:type]) |> Enum.uniq() |> Enum.join(", ")
        {log ++ ["PASS: #{length(agent_events)} events found for agent. Types: #{types}"], assertions + 1, failures}
      else
        {log ++ ["FAIL: Expected >= 2 events, found #{length(agent_events)}"], assertions + 1, failures + 1}
      end

    # Verify state
    state = StateManager.get_state(agent_id)
    {log, assertions, failures} =
      if state && state["phase"] == "complete" do
        {log ++ ["PASS: State delta applied (phase=complete)"], assertions + 1, failures}
      else
        {log ++ ["FAIL: State not in expected state: #{inspect(state)}"], assertions + 1, failures + 1}
      end

    # Verify router stats updated
    stats = EventRouter.stats()
    {log, assertions, failures} =
      if stats.routed_count > 0 do
        {log ++ ["PASS: Router has processed #{stats.routed_count} events"], assertions + 1, failures}
      else
        {log ++ ["FAIL: Router routed_count is 0"], assertions + 1, failures + 1}
      end

    # Cleanup
    StateManager.remove_state(agent_id)

    status = if failures == 0, do: :pass, else: :fail
    {status, log, assertions, failures}
  end

  defp run_test_case(_unknown) do
    {:skip, ["Unknown test case"], 0, 0}
  end

  # -- Render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-100 overflow-hidden">
      <.sidebar_nav current_path="/uat" />

      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="bg-base-200 border-b border-base-300 px-4 py-2 flex items-center justify-between flex-shrink-0">
          <div class="flex items-center gap-3">
            <h1 class="font-semibold text-sm">UAT Integration Testing</h1>
            <span class={["badge badge-sm", summary_badge(@tests)]}>
              {test_summary(@tests)}
            </span>
          </div>
          <div class="flex items-center gap-2">
            <span :if={@last_run_at} class="text-xs text-base-content/40">
              Run #{@run_count} at {format_time(@last_run_at)}
            </span>
            <button
              phx-click="run_all"
              disabled={@running}
              class="btn btn-xs btn-primary gap-1"
            >
              <.icon name="hero-play" class="size-3.5" />
              {if @running, do: "Running...", else: "Run All Tests"}
            </button>
          </div>
        </header>

        <div class="flex-1 flex overflow-hidden">
          <%!-- Test List --%>
          <div class="w-80 border-r border-base-300 overflow-y-auto flex-shrink-0">
            <div :for={category <- categories(@tests)} class="border-b border-base-300">
              <div class="px-3 py-1.5 bg-base-200/50 text-xs font-semibold text-base-content/50 uppercase tracking-wider">
                {category}
              </div>
              <div
                :for={test <- tests_for_category(@tests, category)}
                phx-click="select_test"
                phx-value-id={test.id}
                class={[
                  "px-3 py-2 cursor-pointer border-l-3 flex items-center justify-between hover:bg-base-200 transition-colors",
                  test_row_class(test, @selected_test)
                ]}
              >
                <div class="flex items-center gap-2 min-w-0">
                  <span class={["w-2 h-2 rounded-full flex-shrink-0", status_dot(test.status)]}></span>
                  <span class="text-sm truncate">{test.name}</span>
                </div>
                <div class="flex items-center gap-2 flex-shrink-0">
                  <span :if={test.duration_ms > 0} class="text-xs text-base-content/40 font-mono">
                    {test.duration_ms}ms
                  </span>
                  <button
                    phx-click="run_test"
                    phx-value-id={test.id}
                    class="btn btn-xs btn-ghost p-0.5"
                    title="Run this test"
                  >
                    <.icon name="hero-play" class="size-3" />
                  </button>
                </div>
              </div>
            </div>
          </div>

          <%!-- Test Detail / Log --%>
          <div class="flex-1 flex flex-col overflow-hidden">
            <div :if={@selected_test} class="flex-1 overflow-y-auto p-4">
              <% test = Enum.find(@tests, &(&1.id == @selected_test)) %>
              <div :if={test} class="space-y-3">
                <div class="flex items-center justify-between">
                  <h2 class="font-semibold">{test.name}</h2>
                  <div class="flex items-center gap-2">
                    <span class={["badge badge-sm", status_badge(test.status)]}>
                      {test.status}
                    </span>
                    <span :if={test.assertions > 0} class="text-xs text-base-content/60">
                      {test.assertions - test.failures}/{test.assertions} assertions
                    </span>
                  </div>
                </div>

                <div :if={test.log != []} class="bg-base-200 rounded-lg p-3 font-mono text-xs space-y-0.5 max-h-96 overflow-y-auto">
                  <div :for={line <- test.log} class={log_line_class(line)}>
                    {line}
                  </div>
                </div>

                <div :if={test.log == []} class="text-center py-8 text-base-content/40 text-sm">
                  Test not yet run. Click "Run All Tests" or the play button.
                </div>
              </div>
            </div>

            <div :if={!@selected_test} class="flex-1 flex items-center justify-center">
              <div class="text-center text-base-content/40">
                <.icon name="hero-beaker" class="size-12 mx-auto mb-2 opacity-30" />
                <p class="text-sm">Select a test to view details</p>
                <p class="text-xs mt-1">or click "Run All Tests" to execute the full suite</p>
              </div>
            </div>

            <%!-- Summary Bar --%>
            <div class="border-t border-base-300 bg-base-200 px-4 py-2 flex items-center justify-between flex-shrink-0">
              <div class="flex items-center gap-4 text-xs">
                <span class="text-success">{count_status(@tests, :pass)} passed</span>
                <span class="text-error">{count_status(@tests, :fail)} failed</span>
                <span class="text-warning">{count_status(@tests, :error)} errors</span>
                <span class="text-base-content/40">{count_status(@tests, :pending)} pending</span>
              </div>
              <div class="text-xs text-base-content/40">
                {total_assertions(@tests)} assertions | {total_duration(@tests)}ms total
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # -- View Helpers -----------------------------------------------------------

  defp categories(tests) do
    tests |> Enum.map(& &1.category) |> Enum.uniq()
  end

  defp tests_for_category(tests, category) do
    Enum.filter(tests, &(&1.category == category))
  end

  defp test_summary(tests) do
    pass = count_status(tests, :pass)
    fail = count_status(tests, :fail)
    total = length(tests)
    "#{pass}/#{total} pass#{if fail > 0, do: ", #{fail} fail", else: ""}"
  end

  defp summary_badge(tests) do
    cond do
      Enum.all?(tests, &(&1.status == :pending)) -> "badge-ghost"
      Enum.all?(tests, &(&1.status == :pass)) -> "badge-success"
      Enum.any?(tests, &(&1.status in [:fail, :error])) -> "badge-error"
      true -> "badge-warning"
    end
  end

  defp count_status(tests, status) do
    Enum.count(tests, &(&1.status == status))
  end

  defp total_assertions(tests) do
    Enum.sum(Enum.map(tests, & &1.assertions))
  end

  defp total_duration(tests) do
    Enum.sum(Enum.map(tests, & &1.duration_ms))
  end

  defp status_dot(:pass), do: "bg-success"
  defp status_dot(:fail), do: "bg-error"
  defp status_dot(:error), do: "bg-warning"
  defp status_dot(:skip), do: "bg-info"
  defp status_dot(:pending), do: "bg-base-content/20"

  defp status_badge(:pass), do: "badge-success"
  defp status_badge(:fail), do: "badge-error"
  defp status_badge(:error), do: "badge-warning"
  defp status_badge(:skip), do: "badge-info"
  defp status_badge(:pending), do: "badge-ghost"

  defp test_row_class(test, selected_test) do
    cond do
      test.id == selected_test -> "bg-primary/10 border-l-primary"
      test.status == :pass -> "border-l-success/50"
      test.status == :fail -> "border-l-error/50"
      test.status == :error -> "border-l-warning/50"
      true -> "border-l-transparent"
    end
  end

  defp log_line_class(line) do
    cond do
      String.starts_with?(line, "PASS:") -> "text-success"
      String.starts_with?(line, "FAIL:") -> "text-error"
      String.starts_with?(line, "EXCEPTION:") -> "text-error font-bold"
      true -> "text-base-content/70"
    end
  end

  defp format_time(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> iso_string
    end
  end
end
