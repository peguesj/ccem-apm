defmodule ApmV5.GenServerHelpers do
  @moduledoc """
  Helpers for ensuring required GenServer processes are alive before each test.
  These processes run under the supervision tree but can exceed restart intensity
  under rapid concurrent test failures, causing 'no process' cascades.
  """

  @supervised_processes [
    ApmV5.AgentRegistry,
    ApmV5.AuditLog,
    ApmV5.AlertRulesEngine,
    ApmV5.MetricsCollector,
    ApmV5.SloEngine,
    ApmV5.EventStream,
    ApmV5.SkillTracker
  ]

  @doc """
  Ensures all required GenServer processes are alive.
  Call in test setup blocks before any GenServer interactions.
  """
  def ensure_processes_alive do
    for module <- @supervised_processes do
      case Process.whereis(module) do
        nil ->
          case module.start_link([]) do
            {:ok, _} -> :ok
            {:error, {:already_started, _}} -> :ok
            _ -> :ok
          end

        _pid ->
          :ok
      end
    end

    :ok
  end
end
