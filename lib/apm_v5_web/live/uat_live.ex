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
     socket
     |> assign(
       page_title: "UAT",
       tests: initial_tests(),
       running: false,
       run_count: 0,
       last_run_at: nil,
       selected_test: nil,
       test_log: [],
       sidebar_collapsed: false,
       inspector_open: false
     )
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
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
    {:noreply, assign(socket, selected_test: test_id, inspector_open: true)}
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
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar><.sidebar_nav current_path="/uat" /></:sidebar>
      <:topbar><.top_bar project_name="CCEM APM" /></:topbar>
      <:main>
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
          <div style="display: flex; align-items: center; gap: 10px;">
            <h1 style="margin: 0; font-size: 16px; font-weight: 600; color: var(--ccem-fg);">UAT Integration Testing</h1>
            <.badge tone={summary_tone(@tests)}>{test_summary(@tests)}</.badge>
          </div>
          <div style="display: flex; align-items: center; gap: 10px;">
            <span :if={@last_run_at} style="font-size: 11px; color: var(--ccem-fg-muted);">
              Run {@run_count} at {format_time(@last_run_at)}
            </span>
            <.btn variant="primary" size="sm" phx-click="run_all" disabled={@running}>
              {if @running, do: "Running...", else: "Run All Tests"}
            </.btn>
          </div>
        </div>

        <div style="display: flex; gap: 12px; margin-bottom: 16px;">
          <.card padded={false} style="flex: 1; padding: 12px 16px;">
            <.stat_tile label="Passed" value={to_string(count_status(@tests, :pass))} delta_direction="up" />
          </.card>
          <.card padded={false} style="flex: 1; padding: 12px 16px;">
            <.stat_tile label="Failed" value={to_string(count_status(@tests, :fail))} delta_direction="down" />
          </.card>
          <.card padded={false} style="flex: 1; padding: 12px 16px;">
            <.stat_tile label="Errors" value={to_string(count_status(@tests, :error))} />
          </.card>
          <.card padded={false} style="flex: 1; padding: 12px 16px;">
            <.stat_tile label="Pending" value={to_string(count_status(@tests, :pending))} />
          </.card>
          <.card padded={false} style="flex: 1; padding: 12px 16px;">
            <.stat_tile label="Assertions" value={to_string(total_assertions(@tests))} />
          </.card>
          <.card padded={false} style="flex: 1; padding: 12px 16px;">
            <.stat_tile label="Duration" value={"#{total_duration(@tests)}ms"} />
          </.card>
        </div>

        <.card padded={false}>
          <.data_table id="uat-tests-table" rows={@tests}>
            <:col :let={row} label="Test">
              <span style="font-size: 13px; color: var(--ccem-fg);">{row[:name]}</span>
            </:col>
            <:col :let={row} label="Category">
              <span style="font-size: 11px; color: var(--ccem-fg-muted); font-family: monospace;">{row[:category]}</span>
            </:col>
            <:col :let={row} label="Status">
              <.badge tone={status_tone(row[:status])}>{to_string(row[:status])}</.badge>
            </:col>
            <:col :let={row} label="Assertions">
              <span :if={row[:assertions] > 0} style="font-size: 12px; color: var(--ccem-fg-muted);">
                {row[:assertions] - row[:failures]}/{row[:assertions]}
              </span>
              <span :if={row[:assertions] == 0} style="font-size: 12px; color: var(--ccem-fg-muted);">—</span>
            </:col>
            <:col :let={row} label="Duration">
              <span :if={row[:duration_ms] > 0} style="font-size: 12px; font-family: monospace; color: var(--ccem-fg-muted);">
                {row[:duration_ms]}ms
              </span>
              <span :if={row[:duration_ms] == 0} style="font-size: 12px; color: var(--ccem-fg-muted);">—</span>
            </:col>
            <:col :let={row} label="">
              <div style="display: flex; gap: 6px; justify-content: flex-end;">
                <.btn variant="ghost" size="xs" phx-click="select_test" phx-value-id={row[:id]}>
                  View
                </.btn>
                <.btn variant="ghost" size="xs" phx-click="run_test" phx-value-id={row[:id]} disabled={@running}>
                  Run
                </.btn>
              </div>
            </:col>
          </.data_table>
        </.card>
      </:main>
      <:inspector>
        <div style="padding: 16px;">
          <div :if={@selected_test}>
            <% test = Enum.find(@tests, &(&1.id == @selected_test)) %>
            <div :if={test}>
              <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px;">
                <span style="font-size: 13px; font-weight: 600; color: var(--ccem-fg);">{test.name}</span>
                <.badge tone={status_tone(test.status)}>{to_string(test.status)}</.badge>
              </div>
              <div style="margin-bottom: 12px;">
                <div style="display: flex; gap: 16px; font-size: 11px; color: var(--ccem-fg-muted);">
                  <span>Category: <strong style="color: var(--ccem-fg);">{test.category}</strong></span>
                  <span :if={test.assertions > 0}>
                    Assertions: <strong style="color: var(--ccem-fg);">{test.assertions - test.failures}/{test.assertions}</strong>
                  </span>
                  <span :if={test.duration_ms > 0}>
                    Duration: <strong style="color: var(--ccem-fg);">{test.duration_ms}ms</strong>
                  </span>
                </div>
              </div>
              <div :if={test.log != []}>
                <div style="font-size: 11px; font-weight: 600; color: var(--ccem-fg-muted); margin-bottom: 6px; text-transform: uppercase; letter-spacing: 0.05em;">
                  Log
                </div>
                <div style="background: var(--ccem-surface-raised); border-radius: 6px; padding: 10px; font-family: monospace; font-size: 11px; max-height: 320px; overflow-y: auto; display: flex; flex-direction: column; gap: 2px;">
                  <div :for={line <- test.log} style={"color: #{log_line_color(line)};"}>
                    {line}
                  </div>
                </div>
              </div>
              <div :if={test.log == []}>
                <p style="font-size: 12px; color: var(--ccem-fg-muted); text-align: center; padding: 24px 0;">
                  Test not yet run. Click Run to execute.
                </p>
              </div>
            </div>
          </div>
          <div :if={!@selected_test}>
            <p style="font-size: 12px; color: var(--ccem-fg-muted); text-align: center; padding: 40px 0;">
              Select a test to view details.
            </p>
          </div>
        </div>
      </:inspector>
    </.page_layout>
    """
  end

  # -- View Helpers -----------------------------------------------------------

  defp test_summary(tests) do
    pass = count_status(tests, :pass)
    fail = count_status(tests, :fail)
    total = length(tests)
    "#{pass}/#{total} pass#{if fail > 0, do: ", #{fail} fail", else: ""}"
  end

  defp summary_tone(tests) do
    cond do
      Enum.all?(tests, &(&1.status == :pending)) -> "neutral"
      Enum.all?(tests, &(&1.status == :pass)) -> "success"
      Enum.any?(tests, &(&1.status in [:fail, :error])) -> "error"
      true -> "warning"
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

  defp status_tone(:pass), do: "success"
  defp status_tone(:fail), do: "error"
  defp status_tone(:error), do: "warning"
  defp status_tone(:skip), do: "info"
  defp status_tone(:pending), do: "neutral"

  defp log_line_color(line) do
    cond do
      String.starts_with?(line, "PASS:") -> "var(--ccem-ok)"
      String.starts_with?(line, "FAIL:") -> "var(--ccem-err)"
      String.starts_with?(line, "EXCEPTION:") -> "var(--ccem-err)"
      true -> "var(--ccem-fg-muted)"
    end
  end

  defp format_time(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> iso_string
    end
  end
end
