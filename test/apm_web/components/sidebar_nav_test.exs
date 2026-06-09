defmodule ApmWeb.Components.SidebarNavTest do
  @moduledoc """
  Formation-934 / apm-ui-fix — sidebar render invariants.

  These tests pin the layout chrome that the regression in DIAGNOSIS.md
  caused to collapse. They are RED before squadron 3 ships the defensive
  inline-style augmentation; they go GREEN after.
  """
  use ApmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias ApmWeb.Components.SidebarNav

  @assigns %{
    current_path: "/",
    skill_count: 0,
    notification_count: 0,
    plugins: [],
    integrations: []
  }

  describe "sidebar_nav/1 layout invariants" do
    test "renders an <aside id=\"apm-sidebar\">" do
      html = render_component(&SidebarNav.sidebar_nav/1, @assigns)
      assert html =~ ~s(id="apm-sidebar")
      assert html =~ "<aside"
    end

    test "carries a defensive inline width so the sidebar renders even without Tailwind" do
      # The regression was Tailwind classes silently dropped; w-52 became 0.
      # Defense: an inline style asserting a width >= 192px.
      html = render_component(&SidebarNav.sidebar_nav/1, @assigns)

      assert html =~ ~r/style="[^"]*width:\s*(19[2-9]|2[0-9]{2})px/,
             "sidebar must carry an inline width fallback (>=192px) so the broken Tailwind scanner can't collapse it"
    end

    test "carries an inline background so the sidebar is visually distinct" do
      html = render_component(&SidebarNav.sidebar_nav/1, @assigns)

      assert html =~ ~r/style="[^"]*background:\s*var\(--apm-surface/,
             "sidebar must carry an inline background fallback"
    end

    test "carries inline display:flex and flex-direction:column" do
      html = render_component(&SidebarNav.sidebar_nav/1, @assigns)
      assert html =~ ~r/style="[^"]*display:\s*flex/
      assert html =~ ~r/style="[^"]*flex-direction:\s*column/
    end

    test "renders all six section headers" do
      html = render_component(&SidebarNav.sidebar_nav/1, @assigns)

      for label <- ["Observe", "Govern", "Measure", "Intelligence", "Extend", "AI Platform"] do
        assert html =~ label, "section header '#{label}' missing"
      end
    end
  end
end
