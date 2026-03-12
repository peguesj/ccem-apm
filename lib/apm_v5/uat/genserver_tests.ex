defmodule ApmV5.Uat.GenServerTests do
  @moduledoc """
  UAT test suite that verifies all 34 expected GenServers are registered and alive.

  For each GenServer, calls `Process.whereis/1` and `Process.alive?/1` to confirm
  the process is running under the supervision tree.
  """

  @behaviour ApmV5.Uat.TestSuite

  @genservers [
    {"GS-001", ApmV5.ConfigLoader},
    {"GS-002", ApmV5.DashboardStore},
    {"GS-003", ApmV5.ApiKeyStore},
    {"GS-004", ApmV5.AuditLog},
    {"GS-005", ApmV5.ProjectStore},
    {"GS-006", ApmV5.AgentRegistry},
    {"GS-007", ApmV5.UpmStore},
    {"GS-008", ApmV5.SkillTracker},
    {"GS-009", ApmV5.AlertRulesEngine},
    {"GS-010", ApmV5.MetricsCollector},
    {"GS-011", ApmV5.SloEngine},
    {"GS-012", ApmV5.EventStream},
    {"GS-013", ApmV5.AgentDiscovery},
    {"GS-014", ApmV5.EnvironmentScanner},
    {"GS-015", ApmV5.CommandRunner},
    {"GS-016", ApmV5.DocsStore},
    {"GS-017", ApmV5.PortManager},
    {"GS-018", ApmV5.WorkflowSchemaStore},
    {"GS-019", ApmV5.SkillHookDeployer},
    {"GS-020", ApmV5.VerifyStore},
    {"GS-021", ApmV5.BackgroundTasksStore},
    {"GS-022", ApmV5.ProjectScanner},
    {"GS-023", ApmV5.ActionEngine},
    {"GS-024", ApmV5.AnalyticsStore},
    {"GS-025", ApmV5.HealthCheckRunner},
    {"GS-026", ApmV5.ConversationWatcher},
    {"GS-027", ApmV5.PluginScanner},
    {"GS-028", ApmV5.BackfillStore},
    {"GS-029", ApmV5.SkillsRegistryStore},
    {"GS-030", ApmV5.AgUi.StateManager},
    {"GS-031", ApmV5.AgUi.EventRouter},
    {"GS-032", ApmV5.ChatStore},
    {"GS-033", ApmV5.Intake.Store},
    {"GS-034", ApmV5.ConnectionTracker}
  ]

  @impl true
  @spec category() :: :genserver
  def category, do: :genserver

  @impl true
  @spec count() :: non_neg_integer()
  def count, do: length(@genservers)

  @impl true
  @spec run() :: [map()]
  def run do
    Enum.map(@genservers, fn {id, module} ->
      check_genserver(id, module)
    end)
  end

  # --- Private Helpers ---

  @spec check_genserver(String.t(), module()) :: map()
  defp check_genserver(id, module) do
    start = System.monotonic_time(:millisecond)

    try do
      case Process.whereis(module) do
        nil ->
          result(:failed, id, module, start, "Process not registered")

        pid when is_pid(pid) ->
          if Process.alive?(pid) do
            result(:passed, id, module, start, "PID #{inspect(pid)} alive")
          else
            result(:failed, id, module, start, "PID #{inspect(pid)} not alive")
          end
      end
    rescue
      e ->
        result(:failed, id, module, start, "Error: #{Exception.message(e)}")
    end
  end

  @spec result(atom(), String.t(), module(), integer(), String.t()) :: map()
  defp result(status, id, module, start, message) do
    duration_ms = System.monotonic_time(:millisecond) - start

    %{
      id: id,
      category: :genserver,
      name: inspect(module),
      status: status,
      duration_ms: duration_ms,
      message: message,
      tested_at: DateTime.utc_now()
    }
  end
end
