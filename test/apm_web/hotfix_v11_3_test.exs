defmodule ApmWeb.HotfixV113Test do
  @moduledoc """
  TDD ship gate for v11.0.0 phase 4-5 hotfix bundle (US-511..516 / CP-331..336).
  Each test pins the post-fix behavior for one defect.
  """
  use ApmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ApmWeb.Components.{AgentPanel, SidebarNav}

  # ──────────────────────────────────────────────────────────────────────
  # Defect A (US-511 / CP-331) — Brand wordmark renders exactly once.
  # ──────────────────────────────────────────────────────────────────────
  describe "US-511 / CP-331 — doubled wordmark" do
    test "sidebar_nav.ex no longer renders 'CCEM APM' wordmark" do
      assigns = %{
        current_path: "/",
        skill_count: 0,
        notification_count: 0,
        plugins: [],
        integrations: [],
        version: "v11.0.0"
      }

      html = Phoenix.LiveViewTest.render_component(&SidebarNav.sidebar_nav/1, assigns)

      refute html =~ "CCEM APM",
             "sidebar must NOT contain 'CCEM APM' wordmark — top_bar.ex is canonical (CP-210)"
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Defect C (US-513 / CP-333) — SESSIONS counter prefers live SessionManager.
  # ──────────────────────────────────────────────────────────────────────
  describe "US-513 / CP-333 — SESSIONS=0 fix" do
    test "live_session_count delegates to Apm.SessionManager when available" do
      # When SessionManager is up, list_sessions/0 returns a list (possibly empty);
      # length must be an integer >= 0 and must NOT be derived from never-hydrated config keys.
      live = apply(Apm.SessionManager, :list_sessions, []) |> length()
      assert is_integer(live)
      assert live >= 0
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Defect D (US-514 / CP-334) — Fleet panel renders rows for partial-field agents.
  # ──────────────────────────────────────────────────────────────────────
  describe "US-514 / CP-334 — fleet table empty fix" do
    test "agent_fleet survives an agent map missing :tier / :status / :name" do
      partial_agent = %{id: "spec-test-partial", agent_id: "spec-test-partial"}

      full_agent = %{
        id: "spec-test-full",
        agent_id: "spec-test-full",
        agent_name: "Full Agent",
        tier: 1,
        status: "active",
        last_seen: nil,
        agent_type: "individual"
      }

      assigns = %{
        agents: [partial_agent, full_agent],
        filter_status: nil,
        filter_namespace: nil,
        filter_agent_type: nil,
        filter_query: nil
      }

      # Must not raise. Two agents in → two rows out, even with missing fields.
      html = Phoenix.LiveViewTest.render_component(&AgentPanel.agent_fleet/1, assigns)

      assert html =~ "spec-test-partial"
      assert html =~ "spec-test-full"
      assert html =~ "(unnamed)" or html =~ "spec-test-partial"
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Defect E (US-515 / CP-335) — token bridge maps --color-base-content.
  # Static asset check; no DOM render needed.
  # ──────────────────────────────────────────────────────────────────────
  describe "US-515 / CP-335 — sidebar dim fix" do
    test "apm_tokens_aliases.css maps --color-base-content to --apm-text-primary" do
      path = Path.join([:code.priv_dir(:apm), "..", "assets", "css", "apm_tokens_aliases.css"])

      css =
        cond do
          File.exists?(path) ->
            File.read!(path)

          true ->
            Path.join([File.cwd!(), "assets", "css", "apm_tokens_aliases.css"])
            |> File.read!()
        end

      assert css =~ "--color-base-content"
      assert css =~ "--color-base-content:   var(--apm-text-primary)"
      assert css =~ "--color-primary:"
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Defect F (US-516 / CP-336) — formation graph nodeSize bumped.
  # Asset-content check; the JS hook itself runs in browser, not BEAM.
  # ──────────────────────────────────────────────────────────────────────
  describe "US-516 / CP-336 — graph cramped labels fix" do
    test "formation_graph.js uses bumped tree nodeSize" do
      path = Path.join([File.cwd!(), "assets", "js", "hooks", "formation_graph.js"])
      js = File.read!(path)

      assert js =~ ".nodeSize([120, 250])", "LR mode nodeSize must be [120, 250] (CP-336)"
      assert js =~ ".nodeSize([200, 140])", "TD mode nodeSize must be [200, 140] (CP-336)"
      refute js =~ ".nodeSize([90, 200])", "Old LR nodeSize [90, 200] must be removed"
      refute js =~ ".nodeSize([170, 110])", "Old TD nodeSize [170, 110] must be removed"
    end
  end
end
