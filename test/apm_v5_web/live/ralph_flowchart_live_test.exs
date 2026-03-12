defmodule ApmV5Web.RalphFlowchartLiveTest do
  use ApmV5Web.ConnCase

  import Phoenix.LiveViewTest

  alias ApmV5.AgentRegistry

  setup do
    ApmV5.GenServerHelpers.ensure_processes_alive()
    AgentRegistry.clear_all()
    :ok
  end

  test "GET /ralph renders the Ralph flowchart LiveView", %{conn: conn} do
    conn = get(conn, ~p"/ralph")
    assert html_response(conn, 200) =~ "Ralph Methodology"
  end

  test "ralph page mounts as LiveView", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/ralph")
    assert html =~ "Ralph Methodology"
  end

  test "flowchart container has correct hook attribute", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ralph")
    assert has_element?(view, ~s{div[id="ralph-flowchart"][phx-hook="RalphFlowchart"]})
  end

  test "flowchart container uses phx-update=ignore", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/ralph")
    assert html =~ ~s(phx-update="ignore")
    assert html =~ ~s(phx-hook="RalphFlowchart")
  end

  test "sidebar shows Ralph as active nav item", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/ralph")
    assert html =~ "Ralph"
    # Ralph nav link should have active styling
    assert html =~ "bg-primary/10 text-primary"
  end

  test "step controls are rendered with Next, Previous, Reset", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/ralph")
    assert html =~ "Next"
    assert html =~ "Previous"
    assert html =~ "Reset"
    assert has_element?(view, ~s{button[phx-click="next_step"]})
    assert has_element?(view, ~s{button[phx-click="prev_step"]})
    assert has_element?(view, ~s{button[phx-click="reset_steps"]})
  end

  test "step counter shows current step of total", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/ralph")
    assert html =~ "Step 10 of 10"
  end

  test "all 10 steps listed in sidebar", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/ralph")
    assert html =~ "You write a PRD"
    assert html =~ "Convert to prd.json"
    assert html =~ "Run ralph.sh"
    assert html =~ "AI picks a story"
    assert html =~ "Implements it"
    assert html =~ "Commits changes"
    assert html =~ "Updates prd.json"
    assert html =~ "Logs to progress.txt"
    assert html =~ "More stories?"
    assert html =~ "Done!"
  end

  test "next_step event advances the step counter", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ralph")

    # Reset to step 1 first
    render_click(view, "reset_steps")
    html = render(view)
    assert html =~ "Step 1 of 10"

    # Advance one step
    html = render_click(view, "next_step")
    assert html =~ "Step 2 of 10"
  end

  test "prev_step event goes back one step", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ralph")

    # Reset to step 1, then advance to step 3
    render_click(view, "reset_steps")
    render_click(view, "next_step")
    render_click(view, "next_step")
    html = render(view)
    assert html =~ "Step 3 of 10"

    # Go back
    html = render_click(view, "prev_step")
    assert html =~ "Step 2 of 10"
  end

  test "reset_steps returns to step 1", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ralph")

    html = render_click(view, "reset_steps")
    assert html =~ "Step 1 of 10"
  end

  test "next_step does not exceed total steps", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ralph")

    # Already at step 10 (all visible), clicking next should stay at 10
    html = render_click(view, "next_step")
    assert html =~ "Step 10 of 10"
  end

  test "prev_step does not go below step 1", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ralph")

    render_click(view, "reset_steps")
    html = render_click(view, "prev_step")
    assert html =~ "Step 1 of 10"
  end

  test "advance_step event works like next_step", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ralph")

    render_click(view, "reset_steps")
    html = render_click(view, "advance_step")
    assert html =~ "Step 2 of 10"
  end

  test "jump_to_step event sets visible count", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ralph")

    html = render_hook(view, "jump_to_step", %{"step" => "5"})
    assert html =~ "Step 5 of 10"
  end

  test "select_step shows step details in sidebar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ralph")

    html = render_click(view, "select_step", %{"step-id" => "1"})
    assert html =~ "You write a PRD"
    assert html =~ "Define what you want to build"
    assert html =~ "setup"
  end

  test "select_step shows decision node details", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ralph")

    html = render_click(view, "select_step", %{"step-id" => "9"})
    assert html =~ "More stories?"
    assert html =~ "Decision node"
    assert html =~ "decision"
  end

  test "select_step shows done node details", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ralph")

    html = render_click(view, "select_step", %{"step-id" => "10"})
    assert html =~ "Done!"
    assert html =~ "All stories complete"
    assert html =~ "done"
  end

  test "clicking unknown step does not show details", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ralph")

    html = render_click(view, "select_step", %{"step-id" => "99"})
    assert html =~ "Click a node to view step details"
  end

  test "step details panel shows placeholder when no step selected", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/ralph")
    assert html =~ "Click a node to view step details"
  end

  test "phase colors are applied via CSS classes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ralph")

    # Select a setup phase step
    html = render_click(view, "select_step", %{"step-id" => "1"})
    assert html =~ "bg-blue-500/20"

    # Select a loop phase step
    html = render_click(view, "select_step", %{"step-id" => "5"})
    assert html =~ "bg-gray-500/20"

    # Select a decision phase step
    html = render_click(view, "select_step", %{"step-id" => "9"})
    assert html =~ "bg-amber-500/20"

    # Select the done step
    html = render_click(view, "select_step", %{"step-id" => "10"})
    assert html =~ "bg-green-500/20"
  end

  test "flowchart renders correctly with all phases", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/ralph")
    # All 4 phase dot colors should be present in the step list
    assert html =~ "bg-blue-500"
    assert html =~ "bg-gray-500"
    assert html =~ "bg-amber-500"
    assert html =~ "bg-green-500"
  end
end
