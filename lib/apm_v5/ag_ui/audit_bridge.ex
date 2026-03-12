defmodule ApmV5.AgUi.AuditBridge do
  @moduledoc """
  Bridges EventBus events to AuditLog for compliance and debugging.

  ## US-040 Acceptance Criteria (DoD):
  - GenServer subscribes to EventBus 'lifecycle:*', 'state:*', 'special:*' topics
  - RUN_STARTED, RUN_FINISHED, RUN_ERROR logged as audit entries
  - STATE_SNAPSHOT events logged with version number
  - Approval gate events logged with gate_id and actor
  - Audit entries queryable via existing GET /api/v2/audit endpoint
  - mix compile --warnings-as-errors passes
  """

  use GenServer

  require Logger

  alias ApmV5.AgUi.EventBus

  # -- Client API -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # -- GenServer Callbacks ----------------------------------------------------

  @impl true
  def init(_opts) do
    EventBus.subscribe("lifecycle:*")
    EventBus.subscribe("state:*")
    EventBus.subscribe("special:*")

    {:ok, %{}}
  end

  @impl true
  def handle_info({:event_bus, _topic, event}, state) do
    log_audit_event(event)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private ----------------------------------------------------------------

  defp log_audit_event(%{type: type, data: data}) when is_map(data) do
    case type do
      "RUN_STARTED" ->
        write_audit("ag_ui.run_started", %{
          agent_id: data[:agent_id],
          run_id: data[:run_id],
          thread_id: data[:thread_id],
          metadata: data[:metadata]
        })

      "RUN_FINISHED" ->
        write_audit("ag_ui.run_finished", %{
          agent_id: data[:agent_id],
          run_id: data[:run_id],
          duration_ms: data[:duration_ms],
          summary: data[:summary]
        })

      "RUN_ERROR" ->
        write_audit("ag_ui.run_error", %{
          agent_id: data[:agent_id],
          run_id: data[:run_id],
          message: data[:message],
          stack_trace: data[:stack_trace]
        })

      "STATE_SNAPSHOT" ->
        write_audit("ag_ui.state_snapshot", %{
          agent_id: data[:agent_id],
          version: data[:version],
          source: data[:source]
        })

      "CUSTOM" ->
        # Check for approval gate events
        case data[:name] do
          name when name in ["approval_request", "approval_approve", "approval_reject"] ->
            write_audit("ag_ui.approval.#{name}", %{
              agent_id: data[:agent_id],
              gate_id: get_in(data, [:value, :gate_id]),
              actor: get_in(data, [:value, :actor]),
              value: data[:value]
            })

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp log_audit_event(_event), do: :ok

  defp write_audit(action, details) do
    actor = details[:agent_id] || "system"
    resource = details[:run_id] || details[:agent_id] || "ag-ui"
    ApmV5.AuditLog.log(action, actor, resource, details)
  rescue
    _ -> :ok
  end
end
