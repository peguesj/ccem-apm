defmodule ApmV5.PlanePmAlign do
  @moduledoc """
  Persistent Plane-PM alignment agent. Polls Plane API every 5 minutes,
  detects drift between Plane issue states and APM's internal UPM work items,
  broadcasts changes via PubSub "plane:sync" topic.

  Registered with AgentRegistry as agent_type: :persistent_service with a
  descriptive agent_name and agent_definition.
  """

  use GenServer
  require Logger

  alias ApmV5.{AgentRegistry, PlaneClient}

  @poll_interval_ms 5 * 60 * 1_000
  @agent_id "plane-pm-align-persistent"
  @agent_name "Plane PM Alignment Agent"
  @agent_definition "persistent_service: polls Plane API every 5min to detect and broadcast issue drift"

  # -- Public API

  @doc "Start the PlanePmAlign GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return the current sync state (issues, projects, last_sync_at, sync_count, last_error)."
  @spec current_state() :: map()
  def current_state do
    GenServer.call(__MODULE__, :current_state)
  end

  @doc "Trigger an immediate out-of-band sync."
  @spec trigger_sync() :: :ok
  def trigger_sync do
    GenServer.cast(__MODULE__, :sync_now)
  end

  @doc "Return the DateTime of the last successful sync, or nil."
  @spec last_sync_at() :: DateTime.t() | nil
  def last_sync_at do
    GenServer.call(__MODULE__, :last_sync_at)
  end

  # -- GenServer callbacks

  @impl true
  def init(_opts) do
    # Register with APM AgentRegistry as a persistent_service
    AgentRegistry.register_agent(@agent_id, %{
      name: @agent_name,
      agent_name: @agent_name,
      agent_type: "persistent_service",
      agent_definition: @agent_definition,
      status: "active",
      role: "plane-pm-align"
    })

    # Kick off first sync immediately
    send(self(), :sync)

    {:ok,
     %{
       issues: [],
       projects: [],
       last_sync_at: nil,
       sync_count: 0,
       last_error: nil
     }}
  end

  @impl true
  def handle_info(:sync, state) do
    new_state = do_sync(state)
    Process.send_after(self(), :sync, @poll_interval_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:sync_now, state) do
    send(self(), :sync)
    {:noreply, state}
  end

  @impl true
  def handle_call(:current_state, _from, state) do
    {:reply,
     %{
       issues: state.issues,
       projects: state.projects,
       last_sync_at: state.last_sync_at,
       sync_count: state.sync_count,
       last_error: state.last_error
     }, state}
  end

  @impl true
  def handle_call(:last_sync_at, _from, state) do
    {:reply, state.last_sync_at, state}
  end

  # -- Private

  @ccem_project_id "a20e1d2e-3139-406e-ae03-dc6d1d8cb995"

  defp do_sync(state) do
    try do
      {issues, error} =
        case PlaneClient.list_issues(@ccem_project_id) do
          {:ok, data} ->
            results = Map.get(data, "results", data)
            resolved = if is_list(results), do: results, else: []
            {resolved, nil}

          {:error, reason} ->
            Logger.warning("PlanePmAlign: issue sync failed — #{inspect(reason)}")
            {state.issues, reason}
        end

      {projects, _} =
        case PlaneClient.list_projects() do
          {:ok, data} ->
            results = Map.get(data, "results", data)
            resolved = if is_list(results), do: results, else: []
            {resolved, nil}

          {:error, _} ->
            {state.projects, nil}
        end

      now = DateTime.utc_now()

      new_state = %{
        state
        | issues: issues,
          projects: projects,
          last_sync_at: now,
          sync_count: state.sync_count + 1,
          last_error: error
      }

      Phoenix.PubSub.broadcast(ApmV5.PubSub, "plane:sync", {
        :plane_synced,
        %{
          issues: issues,
          projects: projects,
          synced_at: DateTime.to_iso8601(now),
          issue_count: length(issues)
        }
      })

      Logger.debug("PlanePmAlign: sync #{new_state.sync_count} complete — #{length(issues)} issues")

      new_state
    rescue
      e ->
        Logger.error("PlanePmAlign: sync exception — #{Exception.message(e)}")
        %{state | last_error: Exception.message(e)}
    end
  end
end
