defmodule ApmWeb.Components.TopBarTest do
  @moduledoc """
  Formation-934 / apm-ui-fix — top_bar render invariants.

  top_bar.ex already uses inline styles for chrome; these tests pin
  that invariant so a future Tailwind-classes-only refactor can't
  reintroduce the regression class.
  """
  use ApmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias ApmWeb.Components.TopBar

  @assigns %{
    project_name: "CCEM",
    project_list: [],
    active_project_id: nil,
    session_count: 3,
    current_user: "Jeremiah",
    on_project_change: nil,
    on_command_bar: nil,
    notification_count: 0
  }

  describe "top_bar/1 chrome" do
    test "renders a <header id=\"apm-top-bar\">" do
      html = render_component(&TopBar.top_bar/1, @assigns)
      assert html =~ ~s(id="apm-top-bar")
      assert html =~ "<header"
    end

    test "header carries an inline height of 48px" do
      html = render_component(&TopBar.top_bar/1, @assigns)

      assert html =~ ~r/style="[^"]*height:\s*48px/,
             "top_bar must carry inline height:48px chrome"
    end

    test "header carries inline horizontal padding (chrome breathing room)" do
      html = render_component(&TopBar.top_bar/1, @assigns)

      assert html =~ ~r/style="[^"]*padding:\s*0\s+16px/,
             "top_bar must carry inline padding so chrome remains even without Tailwind"
    end

    test "renders the CCEM APM logotype" do
      html = render_component(&TopBar.top_bar/1, @assigns)
      assert html =~ "CCEM"
      assert html =~ "APM"
    end

    test "renders an account circle initial when current_user is provided" do
      html = render_component(&TopBar.top_bar/1, @assigns)
      assert html =~ ~s(aria-label="Account")
      assert html =~ ~r/>\s*J\s*</
    end
  end
end
