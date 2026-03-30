defmodule ApmV5Web.V2.PlaneController do
  @moduledoc """
  REST controller for Plane-PM alignment endpoints.

  GET  /api/v2/plane/sync-status — current state from PlanePmAlign GenServer
  POST /api/v2/plane/sync        — trigger an immediate out-of-band sync
  """

  use ApmV5Web, :controller

  alias ApmV5.PlanePmAlign

  @doc "Return the current Plane sync state."
  @spec sync_status(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def sync_status(conn, _params) do
    state = PlanePmAlign.current_state()

    json(conn, %{
      ok: true,
      last_sync_at: format_dt(state.last_sync_at),
      sync_count: state.sync_count,
      issue_count: length(state.issues),
      project_count: length(state.projects),
      last_error: format_error(state.last_error)
    })
  end

  @doc "Trigger an immediate Plane sync and return the new state."
  @spec sync(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def sync(conn, _params) do
    PlanePmAlign.trigger_sync()
    json(conn, %{ok: true, message: "sync triggered"})
  end

  # -- Private ----------------------------------------------------------------

  defp format_dt(nil), do: nil
  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp format_error(nil), do: nil
  defp format_error(err) when is_binary(err), do: err
  defp format_error(err), do: inspect(err)
end
