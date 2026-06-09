defmodule ApmWeb.Components.PageLayoutTest do
  @moduledoc """
  Formation-934 / apm-ui-fix — page_layout structural invariants.

  Pins that the three-zone shell (topbar / sidebar / main) renders with
  inline-style chrome that survives a missing Tailwind utility layer.
  """
  use ApmWeb.ConnCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias ApmWeb.Components.PageLayout

  # A wrapper component that injects the three slots so we can exercise
  # PageLayout.page_layout/1 via render_component/2 without manual TagEngine work.
  defp wrapper(assigns) do
    ~H"""
    <PageLayout.page_layout
      sidebar_collapsed={@sidebar_collapsed}
      inspector_open={false}
    >
      <:sidebar>[[sidebar-slot]]</:sidebar>
      <:topbar>[[topbar-slot]]</:topbar>
      <:main>[[main-slot]]</:main>
    </PageLayout.page_layout>
    """
  end

  defp render_shell(sidebar_collapsed \\ false) do
    render_component(&wrapper/1, %{sidebar_collapsed: sidebar_collapsed})
  end

  describe "page_layout/1 shell" do
    test "renders all three slots" do
      html = render_shell()
      assert html =~ "[[sidebar-slot]]"
      assert html =~ "[[topbar-slot]]"
      assert html =~ "[[main-slot]]"
    end

    test "sidebar zone defaults to 220px (un-collapsed)" do
      html = render_shell(false)
      assert html =~ ~r/width:\s*220px/, "sidebar zone must default to 220px"
    end

    test "sidebar zone collapses to 48px when sidebar_collapsed=true" do
      html = render_shell(true)
      assert html =~ ~r/width:\s*48px/, "sidebar zone must collapse to 48px"
    end

    test "main content zone has inline padding chrome" do
      html = render_shell()
      assert html =~ ~r/padding:\s*var\(--ccem-s-4/,
             "main zone must carry inline padding so content has breathing room"
    end

    test "topbar wrapper renders above the body row" do
      html = render_shell()
      topbar_idx = :binary.match(html, "[[topbar-slot]]") |> elem(0)
      sidebar_idx = :binary.match(html, "[[sidebar-slot]]") |> elem(0)
      assert topbar_idx < sidebar_idx, "topbar must render before sidebar in document order"
    end
  end
end
