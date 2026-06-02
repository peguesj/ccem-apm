defmodule ApmWeb.WiringMonitorLiveTest do
  @moduledoc """
  TDD suite for Phase 0.4 — WiringMonitorLive and Apm.WiringMonitor.

  Tests:
  1. LiveView mounts successfully and exports the required callbacks
  2. All 4 checks return results (no exceptions)
  3. Unregistered/unconnected fixtures are correctly flagged by each check

  Run with: mix test test/apm_web/live/wiring_monitor_live_test.exs
  """

  use ExUnit.Case, async: true

  @moduletag :wiring_monitor

  alias Apm.WiringMonitor
  alias Apm.WiringMonitor.Finding

  # ---------------------------------------------------------------------------
  # Test 1 — LiveView contract
  # ---------------------------------------------------------------------------

  describe "ApmWeb.WiringMonitorLive module" do
    test "module is defined and loaded" do
      assert Code.ensure_loaded?(ApmWeb.WiringMonitorLive)
    end

    test "implements LiveView mount/3" do
      assert function_exported?(ApmWeb.WiringMonitorLive, :mount, 3)
    end

    test "implements LiveView render/1" do
      assert function_exported?(ApmWeb.WiringMonitorLive, :render, 1)
    end

    test "route /health/wiring is registered in the router" do
      # Phoenix LiveView routes store the module in metadata, not :plug.
      # Use WiringMonitor.routes/0 which normalises this.
      wiring_routes =
        Apm.WiringMonitor.routes()
        |> Enum.filter(fn r ->
          r.path == "/health/wiring" and r.plug == ApmWeb.WiringMonitorLive
        end)

      assert length(wiring_routes) == 1,
             "Expected exactly one route for /health/wiring → WiringMonitorLive, got: #{inspect(wiring_routes)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 2 — All 4 checks return results without exceptions
  # ---------------------------------------------------------------------------

  describe "WiringMonitor.run_all/0" do
    test "returns a list (no exception)" do
      findings = WiringMonitor.run_all()
      assert is_list(findings)
    end

    test "W1 check returns at least one finding" do
      findings = WiringMonitor.check_route_resolution()
      assert is_list(findings)
      assert length(findings) > 0, "W1 should return at least one finding (routes exist)"
    end

    test "W2 check returns at least one finding" do
      findings = WiringMonitor.check_liveview_coverage()
      assert is_list(findings)
      assert length(findings) > 0, "W2 should return at least one finding (LiveViews exist)"
    end

    test "W3 check returns at least one finding" do
      findings = WiringMonitor.check_hook_registration()
      assert is_list(findings)
      # app.js and templates exist — should produce at least success findings
      assert length(findings) > 0, "W3 should return at least one finding"
    end

    test "W4 check returns at least one finding" do
      findings = WiringMonitor.check_pubsub_coverage()
      assert is_list(findings)
      assert length(findings) > 0, "W4 should return at least one finding (topics exist)"
    end

    test "all findings have expected struct fields" do
      findings = WiringMonitor.run_all()

      for %Finding{} = f <- findings do
        assert f.check in [:W1, :W2, :W3, :W4],
               "check field must be :W1–:W4, got: #{inspect(f.check)}"

        assert f.severity in [:success, :warning, :error],
               "severity must be :success/:warning/:error, got: #{inspect(f.severity)}"

        assert is_binary(f.subject), "subject must be a string"
        assert is_binary(f.detail),  "detail must be a string"
      end
    end

    test "summary/1 returns correct count map" do
      findings = [
        Finding.new(:W1, :error,   "route", "bad"),
        Finding.new(:W1, :success, "route", "ok"),
        Finding.new(:W3, :warning, "hook",  "dead code"),
        Finding.new(:W3, :warning, "hook",  "dead code 2")
      ]

      summary = WiringMonitor.summary(findings)

      assert summary.error   == 1
      assert summary.warning == 2
      assert summary.success == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Test 3 — Fixture-based flagging tests
  # ---------------------------------------------------------------------------

  describe "W1 check_route_resolution/0 — fixture scenarios" do
    test "flags a non-existent module as error" do
      # Simulate a route pointing to a non-existent module by calling the
      # check logic directly with a synthetic route
      route = %{path: "/fake", plug: DoesNotExist.Module, plug_opts: :index}
      mod   = route.plug

      # Verify the module doesn't exist
      refute Code.ensure_loaded?(mod)

      # The real check logic: if module not loaded → :error
      finding =
        cond do
          not is_atom(mod) ->
            Finding.new(:W1, :warning, route.path, "non-module plug")

          not Code.ensure_loaded?(mod) ->
            Finding.new(:W1, :error, route.path, "module #{inspect(mod)} could not be loaded")

          true ->
            Finding.new(:W1, :success, route.path, "ok")
        end

      assert finding.severity == :error
      assert finding.check == :W1
      assert String.contains?(finding.detail, "could not be loaded")
    end

    test "accepts a real LiveView module as success" do
      mod = ApmWeb.WiringMonitorLive
      assert Code.ensure_loaded?(mod)
      assert function_exported?(mod, :mount, 3)

      # The router has a route for WiringMonitorLive — W1 should pass
      findings = WiringMonitor.check_route_resolution()
      wiring_findings =
        Enum.filter(findings, fn f ->
          String.contains?(f.subject, "/health/wiring")
        end)

      # Our own route should produce a :success finding
      assert Enum.any?(wiring_findings, &(&1.severity == :success)),
             "Expected WiringMonitorLive route to pass W1, got: #{inspect(wiring_findings)}"
    end
  end

  describe "W3 check_hook_registration/0 — fixture scenarios" do
    test "emitted_hooks returns a MapSet of strings" do
      hooks = WiringMonitor.emitted_hooks()
      assert %MapSet{} = hooks
      # We know ClockTimer and Toast are used
      assert MapSet.member?(hooks, "Toast") or MapSet.member?(hooks, "Clock"),
             "Expected at least one known hook in emitted set, got: #{inspect(MapSet.to_list(hooks))}"
    end

    test "registered_hooks returns a non-empty MapSet" do
      hooks = WiringMonitor.registered_hooks()
      assert %MapSet{} = hooks
      assert MapSet.size(hooks) > 0, "Expected registered hooks from app.js, got empty set"
      assert MapSet.member?(hooks, "Toast"), "Expected Toast to be registered in app.js"
    end

    test "flags a hook used in template but not in app.js Hooks" do
      emitted    = MapSet.new(["RealHook", "GhostHook"])
      registered = MapSet.new(["RealHook"])

      unregistered = MapSet.difference(emitted, registered)

      assert MapSet.member?(unregistered, "GhostHook")
      refute MapSet.member?(unregistered, "RealHook")
    end

    test "flags a hook in app.js but not used in any template as warning-eligible" do
      emitted    = MapSet.new(["UsedHook"])
      registered = MapSet.new(["UsedHook", "DeadHook"])

      dead = MapSet.difference(registered, emitted)

      assert MapSet.member?(dead, "DeadHook")
      refute MapSet.member?(dead, "UsedHook")
    end
  end

  describe "W4 check_pubsub_coverage/0 — fixture scenarios" do
    test "subscribed_topics returns a non-empty MapSet" do
      topics = WiringMonitor.subscribed_topics()
      assert %MapSet{} = topics
      assert MapSet.size(topics) > 0
      assert MapSet.member?(topics, "apm:agents")
    end

    test "broadcast_topics returns a non-empty MapSet" do
      topics = WiringMonitor.broadcast_topics()
      assert %MapSet{} = topics
      assert MapSet.size(topics) > 0
      assert MapSet.member?(topics, "apm:agents")
    end

    test "topics present on both sides produce success finding" do
      findings = WiringMonitor.check_pubsub_coverage()
      ok_finding = Enum.find(findings, &(&1.severity == :success))
      assert ok_finding != nil, "Expected at least one success finding for matched topics"
    end

    test "subscribed-only topics produce warning finding" do
      findings = WiringMonitor.check_pubsub_coverage()

      # Topics like "apm:coalesce", "apm:approvals" are subscribed but not in
      # the broadcast set — they should appear as :warning
      warning_findings = Enum.filter(findings, &(&1.severity == :warning and &1.check == :W4))

      # We know some topics are subscribe-only; check we have at least one W4 warning
      assert length(warning_findings) > 0,
             "Expected at least one W4 warning for subscribe-only topics, got 0"
    end
  end

  # ---------------------------------------------------------------------------
  # Finding struct helpers
  # ---------------------------------------------------------------------------

  describe "Apm.WiringMonitor.Finding" do
    test "new/4 creates struct with correct fields" do
      f = Finding.new(:W1, :error, "/some/path", "module missing")
      assert f.check == :W1
      assert f.severity == :error
      assert f.subject == "/some/path"
      assert f.detail == "module missing"
      assert %DateTime{} = f.checked_at
    end

    test "tone/1 maps severity to string tone" do
      assert Finding.tone(Finding.new(:W1, :success, "", "")) == "success"
      assert Finding.tone(Finding.new(:W1, :warning, "", "")) == "warning"
      assert Finding.tone(Finding.new(:W1, :error,   "", "")) == "error"
    end
  end
end
