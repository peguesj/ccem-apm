defmodule ApmWeb.V11RedirectController do
  @moduledoc """
  301 redirect shims for v11 IA route consolidation (Phase 2).

  Old route            → New route
  /approvals           → /decide/pending
  /approvals-history   → /decide/pending?status=resolved
  /sessions/:id        → /investigate/sessions/:id

  Old LiveViews are retained as fallback handlers and are NOT deleted
  until zero-traffic is confirmed on the old paths (no-downtime strategy).

  These are permanent (301) redirects so user agents and search engines
  update their bookmarks without repeated round-trips.
  """

  use ApmWeb, :controller

  @doc "GET /approvals → 301 /decide/pending"
  def approvals(conn, _params) do
    redirect(conn, external: "/decide/pending")
  end

  @doc "GET /approvals-history → 301 /decide/pending?status=resolved"
  def approvals_history(conn, _params) do
    redirect(conn, external: "/decide/pending?status=resolved")
  end

  @doc "GET /sessions/:id → 301 /investigate/sessions/:id"
  def session_detail(conn, %{"id" => id}) do
    redirect(conn, external: "/investigate/sessions/#{id}")
  end
end
