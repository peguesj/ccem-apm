defmodule ApmV5.Auth.AgentLifecycleTest do
  use ExUnit.Case, async: true

  alias ApmV5.Auth.AgentLifecycle

  # ── transition/2 — valid transitions ───────────────────────────────────────

  test "valid transition: pending -> authorized" do
    assert {:ok, :authorized} = AgentLifecycle.transition(:pending, :authorize)
  end

  test "valid transition: pending -> failed via cancel" do
    assert {:ok, :failed} = AgentLifecycle.transition(:pending, :cancel)
  end

  test "valid transition: pending -> timed_out via timeout" do
    assert {:ok, :timed_out} = AgentLifecycle.transition(:pending, :timeout)
  end

  test "valid transition: authorized -> running" do
    assert {:ok, :running} = AgentLifecycle.transition(:authorized, :start)
  end

  test "valid transition: authorized -> failed via cancel" do
    assert {:ok, :failed} = AgentLifecycle.transition(:authorized, :cancel)
  end

  test "valid transition: running -> completing" do
    assert {:ok, :completing} = AgentLifecycle.transition(:running, :complete)
  end

  test "valid transition: running -> failed via fail" do
    assert {:ok, :failed} = AgentLifecycle.transition(:running, :fail)
  end

  test "valid transition: running -> timed_out" do
    assert {:ok, :timed_out} = AgentLifecycle.transition(:running, :timeout)
  end

  test "valid transition: completing -> completed" do
    assert {:ok, :completed} = AgentLifecycle.transition(:completing, :complete)
  end

  test "valid transition: completing -> failed" do
    assert {:ok, :failed} = AgentLifecycle.transition(:completing, :fail)
  end

  # ── transition/2 — invalid transitions ─────────────────────────────────────

  test "invalid transition: pending -> complete" do
    assert {:error, :invalid_transition} = AgentLifecycle.transition(:pending, :complete)
  end

  test "invalid transition: completed -> start" do
    assert {:error, :invalid_transition} = AgentLifecycle.transition(:completed, :start)
  end

  test "invalid transition: failed -> authorize" do
    assert {:error, :invalid_transition} = AgentLifecycle.transition(:failed, :authorize)
  end

  test "invalid transition: timed_out -> start" do
    assert {:error, :invalid_transition} = AgentLifecycle.transition(:timed_out, :start)
  end

  test "invalid transition: authorized -> complete" do
    assert {:error, :invalid_transition} = AgentLifecycle.transition(:authorized, :complete)
  end

  # ── terminal?/1 ────────────────────────────────────────────────────────────

  test "terminal? identifies terminal states" do
    assert AgentLifecycle.terminal?(:completed)
    assert AgentLifecycle.terminal?(:failed)
    assert AgentLifecycle.terminal?(:timed_out)
  end

  test "terminal? returns false for non-terminal states" do
    refute AgentLifecycle.terminal?(:pending)
    refute AgentLifecycle.terminal?(:authorized)
    refute AgentLifecycle.terminal?(:running)
    refute AgentLifecycle.terminal?(:completing)
  end

  # ── valid_events/1 ─────────────────────────────────────────────────────────

  test "valid_events returns events for pending state" do
    events = AgentLifecycle.valid_events(:pending)
    assert :authorize in events
    assert :cancel in events
    assert :timeout in events
    assert length(events) == 3
  end

  test "valid_events returns events for running state" do
    events = AgentLifecycle.valid_events(:running)
    assert :complete in events
    assert :fail in events
    assert :timeout in events
    assert :cancel in events
  end

  test "valid_events returns empty list for terminal states" do
    assert AgentLifecycle.valid_events(:completed) == []
    assert AgentLifecycle.valid_events(:failed) == []
    assert AgentLifecycle.valid_events(:timed_out) == []
  end

  # ── edges/0 ────────────────────────────────────────────────────────────────

  test "edges returns list of transition maps" do
    edges = AgentLifecycle.edges()
    assert is_list(edges)
    assert length(edges) > 0
    assert Enum.all?(edges, fn e ->
      Map.has_key?(e, :from) and Map.has_key?(e, :to) and Map.has_key?(e, :event)
    end)
  end

  test "edges includes pending -> authorized transition" do
    edges = AgentLifecycle.edges()
    assert Enum.any?(edges, fn e ->
      e.from == :pending and e.to == :authorized and e.event == :authorize
    end)
  end

  # ── state_machine/0 ───────────────────────────────────────────────────────

  test "state_machine returns the full transition map" do
    sm = AgentLifecycle.state_machine()
    assert is_map(sm)
    assert Map.has_key?(sm, :pending)
    assert Map.has_key?(sm, :authorized)
    assert Map.has_key?(sm, :running)
    assert Map.has_key?(sm, :completing)
  end

  # ── all_states/0 ───────────────────────────────────────────────────────────

  test "all_states includes all 7 states" do
    states = AgentLifecycle.all_states()
    assert length(states) == 7
    assert :pending in states
    assert :authorized in states
    assert :running in states
    assert :completing in states
    assert :completed in states
    assert :failed in states
    assert :timed_out in states
  end

  # ── full lifecycle path ────────────────────────────────────────────────────

  test "complete happy-path lifecycle: pending -> completed" do
    assert {:ok, s1} = AgentLifecycle.transition(:pending, :authorize)
    assert s1 == :authorized
    assert {:ok, s2} = AgentLifecycle.transition(s1, :start)
    assert s2 == :running
    assert {:ok, s3} = AgentLifecycle.transition(s2, :complete)
    assert s3 == :completing
    assert {:ok, s4} = AgentLifecycle.transition(s3, :complete)
    assert s4 == :completed
    assert AgentLifecycle.terminal?(s4)
  end
end
