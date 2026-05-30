defmodule ApmWeb.PlatformAiPlatformTddTest do
  @moduledoc """
  TDD suite for CP-198: Extend + Platform + AI Platform LiveView module verification.

  Covers:
    CP-192  Extend: PluginDashboardLive (Plugins + Integrations), AgUiLive, NotificationLive, ComposioLive
    CP-193  Extend: ShowcaseLive, DocsLive
    CP-194  Platform: ArchitectureLive, DrtwLive, UatLive
    CP-195  AI Platform: LvmStatusLive
    CP-196  AI Platform: ClaudeCodeDiscoveryLive, RalphPluginLive
    CP-197  AI Platform: AgUiPluginLive

  Run with: mix test --only platform
  """

  use ExUnit.Case, async: true

  @moduletag :platform

  @all_modules [
    ApmWeb.PluginDashboardLive,
    ApmWeb.AgUiLive,
    ApmWeb.NotificationLive,
    ApmWeb.ComposioLive,
    ApmWeb.ShowcaseLive,
    ApmWeb.DocsLive,
    ApmWeb.ArchitectureLive,
    ApmWeb.DrtwLive,
    ApmWeb.UatLive,
    ApmWeb.LvmStatusLive,
    ApmWeb.ClaudeCodeDiscoveryLive,
    ApmWeb.RalphPluginLive,
    ApmWeb.AgUiPluginLive
  ]

  setup_all do
    Enum.each(@all_modules, &Code.ensure_loaded?/1)
    :ok
  end

  # ── Extend: CP-192 ───────────────────────────────────────────────────────────

  describe "ApmWeb.PluginDashboardLive (Plugins + Integrations)" do
    test "module is defined" do
      assert Code.ensure_loaded?(ApmWeb.PluginDashboardLive)
    end

    test "uses Phoenix.LiveView" do
      assert function_exported?(ApmWeb.PluginDashboardLive, :mount, 3)
      assert function_exported?(ApmWeb.PluginDashboardLive, :render, 1)
    end

    test "handles plugin selection events" do
      assert function_exported?(ApmWeb.PluginDashboardLive, :handle_event, 3)
    end
  end

  describe "ApmWeb.AgUiLive (AG-UI Protocol)" do
    test "module is defined" do
      assert Code.ensure_loaded?(ApmWeb.AgUiLive)
    end

    test "uses Phoenix.LiveView" do
      assert function_exported?(ApmWeb.AgUiLive, :mount, 3)
      assert function_exported?(ApmWeb.AgUiLive, :render, 1)
    end
  end

  describe "ApmWeb.NotificationLive (Notifications)" do
    test "module is defined" do
      assert Code.ensure_loaded?(ApmWeb.NotificationLive)
    end

    test "uses Phoenix.LiveView" do
      assert function_exported?(ApmWeb.NotificationLive, :mount, 3)
      assert function_exported?(ApmWeb.NotificationLive, :render, 1)
    end
  end

  describe "ApmWeb.ComposioLive (Integrations)" do
    test "module is defined" do
      assert Code.ensure_loaded?(ApmWeb.ComposioLive)
    end

    test "uses Phoenix.LiveView" do
      assert function_exported?(ApmWeb.ComposioLive, :mount, 3)
      assert function_exported?(ApmWeb.ComposioLive, :render, 1)
    end
  end

  # ── Extend: CP-193 ───────────────────────────────────────────────────────────

  describe "ApmWeb.ShowcaseLive (Showcase)" do
    test "module is defined" do
      assert Code.ensure_loaded?(ApmWeb.ShowcaseLive)
    end

    test "uses Phoenix.LiveView" do
      assert function_exported?(ApmWeb.ShowcaseLive, :mount, 3)
      assert function_exported?(ApmWeb.ShowcaseLive, :render, 1)
    end
  end

  describe "ApmWeb.DocsLive (Documentation)" do
    test "module is defined" do
      assert Code.ensure_loaded?(ApmWeb.DocsLive)
    end

    test "uses Phoenix.LiveView" do
      assert function_exported?(ApmWeb.DocsLive, :mount, 3)
      assert function_exported?(ApmWeb.DocsLive, :render, 1)
    end

    test "handles navigation events" do
      assert function_exported?(ApmWeb.DocsLive, :handle_event, 3)
    end
  end

  # ── Platform: CP-194 ─────────────────────────────────────────────────────────

  describe "ApmWeb.ArchitectureLive (Platform: Architecture)" do
    test "module is defined" do
      assert Code.ensure_loaded?(ApmWeb.ArchitectureLive)
    end

    test "uses Phoenix.LiveView" do
      assert function_exported?(ApmWeb.ArchitectureLive, :mount, 3)
      assert function_exported?(ApmWeb.ArchitectureLive, :render, 1)
    end
  end

  describe "ApmWeb.DrtwLive (Platform: DRTW)" do
    test "module is defined" do
      assert Code.ensure_loaded?(ApmWeb.DrtwLive)
    end

    test "uses Phoenix.LiveView" do
      assert function_exported?(ApmWeb.DrtwLive, :mount, 3)
      assert function_exported?(ApmWeb.DrtwLive, :render, 1)
    end
  end

  describe "ApmWeb.UatLive (Platform: UAT)" do
    test "module is defined" do
      assert Code.ensure_loaded?(ApmWeb.UatLive)
    end

    test "uses Phoenix.LiveView" do
      assert function_exported?(ApmWeb.UatLive, :mount, 3)
      assert function_exported?(ApmWeb.UatLive, :render, 1)
    end
  end

  # ── AI Platform: CP-195 ──────────────────────────────────────────────────────

  describe "ApmWeb.LvmStatusLive (AI Platform: LVM Integration)" do
    test "module is defined" do
      assert Code.ensure_loaded?(ApmWeb.LvmStatusLive)
    end

    test "uses Phoenix.LiveView" do
      assert function_exported?(ApmWeb.LvmStatusLive, :mount, 3)
      assert function_exported?(ApmWeb.LvmStatusLive, :render, 1)
    end
  end

  # ── AI Platform: CP-196 ──────────────────────────────────────────────────────

  describe "ApmWeb.ClaudeCodeDiscoveryLive (AI Platform: Claude Code Discovery)" do
    test "module is defined" do
      assert Code.ensure_loaded?(ApmWeb.ClaudeCodeDiscoveryLive)
    end

    test "uses Phoenix.LiveView" do
      assert function_exported?(ApmWeb.ClaudeCodeDiscoveryLive, :mount, 3)
      assert function_exported?(ApmWeb.ClaudeCodeDiscoveryLive, :render, 1)
    end
  end

  describe "ApmWeb.RalphPluginLive (AI Platform: Ralph Plugin)" do
    test "module is defined" do
      assert Code.ensure_loaded?(ApmWeb.RalphPluginLive)
    end

    test "uses Phoenix.LiveView" do
      assert function_exported?(ApmWeb.RalphPluginLive, :mount, 3)
      assert function_exported?(ApmWeb.RalphPluginLive, :render, 1)
    end
  end

  # ── AI Platform: CP-197 ──────────────────────────────────────────────────────

  describe "ApmWeb.AgUiPluginLive (AI Platform: AG-UI Plugin)" do
    test "module is defined" do
      assert Code.ensure_loaded?(ApmWeb.AgUiPluginLive)
    end

    test "uses Phoenix.LiveView" do
      assert function_exported?(ApmWeb.AgUiPluginLive, :mount, 3)
      assert function_exported?(ApmWeb.AgUiPluginLive, :render, 1)
    end
  end

  # ── Compile gate (CP-198) ────────────────────────────────────────────────────

  describe "v9.2.0 compile gate" do
    test "Apm application module is loaded" do
      assert Code.ensure_loaded?(Apm)
    end

    test "ApmWeb router is loaded" do
      assert Code.ensure_loaded?(ApmWeb.Router)
    end

    test "ApmWeb endpoint is loaded" do
      assert Code.ensure_loaded?(ApmWeb.Endpoint)
    end

    test "all Extend LiveViews are loaded" do
      for mod <- [
        ApmWeb.PluginDashboardLive,
        ApmWeb.AgUiLive,
        ApmWeb.NotificationLive,
        ApmWeb.ComposioLive,
        ApmWeb.ShowcaseLive,
        ApmWeb.DocsLive
      ] do
        assert Code.ensure_loaded?(mod), "Expected #{mod} to be loaded"
      end
    end

    test "all Platform LiveViews are loaded" do
      for mod <- [
        ApmWeb.ArchitectureLive,
        ApmWeb.DrtwLive,
        ApmWeb.UatLive
      ] do
        assert Code.ensure_loaded?(mod), "Expected #{mod} to be loaded"
      end
    end

    test "all AI Platform LiveViews are loaded" do
      for mod <- [
        ApmWeb.LvmStatusLive,
        ApmWeb.ClaudeCodeDiscoveryLive,
        ApmWeb.RalphPluginLive,
        ApmWeb.AgUiPluginLive
      ] do
        assert Code.ensure_loaded?(mod), "Expected #{mod} to be loaded"
      end
    end
  end
end
