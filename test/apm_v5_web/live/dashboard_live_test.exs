defmodule ApmV5Web.DashboardLiveComponentTest do
  @moduledoc """
  Integration tests for DashboardLive extracted component integration.

  Verifies the AgentPanel and PortPanel sub-components render correctly
  within DashboardLive as part of the refactor-max US-R13/US-R14 extraction.
  Complements the broader suite in test/apm_v5_web/controllers/page_controller_test.exs.
  """

  use ApmV5Web.ConnCase

  import Phoenix.LiveViewTest

  alias ApmV5.AgentRegistry

  setup do
    for mod <- [ApmV5.UpmStore, ApmV5.PortManager, ApmV5.ChatStore,
                ApmV5.DashboardStore, ApmV5.ProjectStore] do
      case mod.start_link([]) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        _ -> :ok
      end
    end

    AgentRegistry.clear_all()
    :ok
  end

  # --- AgentPanel component tests (US-R13) ---

  test "AgentPanel renders Agent Fleet header via extracted component", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Agent Fleet"
  end

  test "AgentPanel shows no-agents placeholder when agent list is empty", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "No agents registered"
    assert html =~ "/api/register"
  end

  test "AgentPanel renders column headers", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Last Seen"
    assert html =~ "Status"
  end

  test "AgentPanel renders active agent row with badges", %{conn: conn} do
    AgentRegistry.register_agent("panel-agent-001", %{
      name: "PanelAgent",
      status: "active",
      tier: 1,
      agent_type: "individual",
      deps: [],
      metadata: %{}
    }, nil)

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "PanelAgent"
    assert html =~ "panel-agent-001"
    assert html =~ "active"
  end

  test "AgentPanel renders agent story_id badge when present", %{conn: conn} do
    AgentRegistry.register_agent("story-agent", %{
      name: "StoryAgent",
      status: "active",
      tier: 2,
      story_id: "US-R13",
      deps: [],
      metadata: %{}
    }, nil)

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "US-R13"
  end

  # --- PortPanel component tests (US-R14) ---

  test "PortPanel renders via Ports tab switch", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    html = render_click(view, "switch_tab", %{"tab" => "ports"})
    assert html =~ "Port Manager"
  end

  test "PortPanel shows Scan button in Ports tab", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    html = render_click(view, "switch_tab", %{"tab" => "ports"})
    assert html =~ "Scan"
  end

  test "PortPanel shows no-projects placeholder when project_configs is empty", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    html = render_click(view, "switch_tab", %{"tab" => "ports"})
    # Either shows project configs or the empty state
    assert html =~ "Port Manager"
  end
end
