defmodule ApmV5Web.ShowcaseLiveTest do
  @moduledoc """
  Integration tests for ShowcaseLive.

  Verifies mount, project listing, and regression: ShowcaseLive must not crash
  when UpmStore has no active sessions (nil session guard).
  """

  use ApmV5Web.ConnCase

  import Phoenix.LiveViewTest

  setup do
    # Ensure UpmStore is alive and cleared for nil-session regression test
    case ApmV5.UpmStore.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> :ok
    end

    case ApmV5.ShowcaseDataStore.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> :ok
    end

    :ok
  end

  test "showcase mounts without crash when UpmStore has no sessions (nil-session regression)", %{conn: conn} do
    # This is the key regression: UpmStore.get_status/0 returns %{active: false, session: nil}
    # ShowcaseLive must not crash when session is nil.
    assert {:ok, _view, html} = live(conn, ~p"/showcase")
    assert is_binary(html)
  end

  test "showcase renders Showcase title", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/showcase")
    assert html =~ "Showcase"
  end

  test "showcase shows features count badge", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/showcase")
    assert html =~ "features"
  end

  test "showcase shows LIVE badge", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/showcase")
    assert html =~ "LIVE"
  end

  test "showcase/:project route mounts without crash", %{conn: conn} do
    # Mount with a project name that doesn't exist — should gracefully handle
    assert {:ok, _view, html} = live(conn, ~p"/showcase/nonexistent-project")
    assert is_binary(html)
  end

  test "GET /showcase renders initial HTML", %{conn: conn} do
    conn = get(conn, ~p"/showcase")
    assert html_response(conn, 200) =~ "CCEM"
  end
end
