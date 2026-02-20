ExUnit.start()

# Start required GenServer processes for tests.
# config/test.exs sets start_services: false which prevents application.ex
# from starting these. Tests rely on them as named processes, so we start
# them here globally for the test suite.
for module <- [
  ApmV4.AgentRegistry,
  ApmV4.AuditLog
] do
  case module.start_link([]) do
    {:ok, _pid} -> :ok
    {:error, {:already_started, _pid}} -> :ok
    {:error, reason} ->
      IO.puts("Warning: Could not start #{inspect(module)}: #{inspect(reason)}")
  end
end
