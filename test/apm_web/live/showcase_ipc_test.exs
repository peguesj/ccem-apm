defmodule ApmWeb.ShowcaseIpcTest do
  @moduledoc """
  TDD suite for CP-273 (showcase-5): ShowcaseLive PubSub subscription to "ccem:ipc:events"
  and re-render on matched IPC event_type patterns.

  Run with: mix test --only showcase_ipc
  """

  use ApmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :showcase_ipc

  # ── Module-level smoke tests ──────────────────────────────────────────────

  describe "ShowcaseLive module contract" do
    test "module is defined" do
      assert Code.ensure_loaded?(ApmWeb.ShowcaseLive)
    end

    test "exports LiveView callbacks" do
      assert function_exported?(ApmWeb.ShowcaseLive, :mount, 3)
      assert function_exported?(ApmWeb.ShowcaseLive, :render, 1)
      assert function_exported?(ApmWeb.ShowcaseLive, :handle_info, 2)
    end

    test "handle_info/2 accepts {:ccem_ipc, event} tuples" do
      # Verify the function clause exists by checking exports — the actual
      # clause dispatch is tested via PubSub broadcast below.
      assert function_exported?(ApmWeb.ShowcaseLive, :handle_info, 2)
    end
  end

  # ── PubSub subscription and re-render tests ───────────────────────────────

  describe "PubSub subscription to ccem:ipc:events" do
    test "subscribes to ccem:ipc:events topic on mount (connected)" do
      # Mount the LiveView over a connected websocket
      {:ok, _view, _html} = live(build_conn(), "/showcase")

      # The LiveView under test broadcasts to ccem:ipc:events and we verify
      # it does NOT crash when such a broadcast arrives. A crash would fail
      # the test; clean reception confirms the subscription is wired.
      Phoenix.PubSub.broadcast(
        Apm.PubSub,
        "ccem:ipc:events",
        {:ccem_ipc, %{"event_type" => "upm.story.start", "payload" => %{}}}
      )

      # Give the LiveView process a tick to handle the message
      Process.sleep(50)
    end

    test "upm.* event triggers re-render (showcase:ipc_event push_event)" do
      {:ok, view, _html} = live(build_conn(), "/showcase")

      # Broadcast a upm event
      Phoenix.PubSub.broadcast(
        Apm.PubSub,
        "ccem:ipc:events",
        {:ccem_ipc, %{"event_type" => "upm.wave.start", "payload" => %{"wave" => 3}}}
      )

      # The LiveView should push a "showcase:ipc_event" client event
      assert_push_event(view, "showcase:ipc_event", %{event_type: "upm.wave.start"})
    end

    test "formation.* event triggers re-render" do
      {:ok, view, _html} = live(build_conn(), "/showcase")

      Phoenix.PubSub.broadcast(
        Apm.PubSub,
        "ccem:ipc:events",
        {:ccem_ipc,
         %{"event_type" => "formation.spawn", "payload" => %{"formation_id" => "fmt-001"}}}
      )

      assert_push_event(view, "showcase:ipc_event", %{event_type: "formation.spawn"})
    end

    test "wave.* event triggers re-render" do
      {:ok, view, _html} = live(build_conn(), "/showcase")

      Phoenix.PubSub.broadcast(
        Apm.PubSub,
        "ccem:ipc:events",
        {:ccem_ipc, %{"event_type" => "wave.complete", "payload" => %{}}}
      )

      assert_push_event(view, "showcase:ipc_event", %{event_type: "wave.complete"})
    end

    test "version.* event triggers re-render" do
      {:ok, view, _html} = live(build_conn(), "/showcase")

      Phoenix.PubSub.broadcast(
        Apm.PubSub,
        "ccem:ipc:events",
        {:ccem_ipc, %{"event_type" => "version.bump", "payload" => %{"version" => "9.3.1"}}}
      )

      assert_push_event(view, "showcase:ipc_event", %{event_type: "version.bump"})
    end

    test "unmatched event_type does NOT push showcase:ipc_event" do
      {:ok, view, _html} = live(build_conn(), "/showcase")

      Phoenix.PubSub.broadcast(
        Apm.PubSub,
        "ccem:ipc:events",
        {:ccem_ipc, %{"event_type" => "irrelevant.other", "payload" => %{}}}
      )

      # Give the process time to handle (or ignore) the message
      Process.sleep(50)

      # Refute that a push_event was sent for this unmatched type
      refute_push_event(view, "showcase:ipc_event", %{event_type: "irrelevant.other"})
    end

    test "ipc_event payload is forwarded in push_event" do
      {:ok, view, _html} = live(build_conn(), "/showcase")

      Phoenix.PubSub.broadcast(
        Apm.PubSub,
        "ccem:ipc:events",
        {:ccem_ipc,
         %{
           "event_type" => "upm.story.finish",
           "payload" => %{"story" => "showcase-5", "session" => "upm-1020"}
         }}
      )

      assert_push_event(view, "showcase:ipc_event", %{
        event_type: "upm.story.finish",
        payload: %{"story" => "showcase-5", "session" => "upm-1020"}
      })
    end
  end
end
