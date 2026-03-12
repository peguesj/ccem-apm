defmodule ApmV5Web.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ApmV5Web.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ApmV5Web.Endpoint

      use ApmV5Web, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ApmV5Web.ConnCase
    end
  end

  setup _tags do
    # Ensure AgentRegistry and AuditLog are alive before each test.
    # They run under the supervision tree but may exceed restart intensity
    # under rapid concurrent test failures.
    for module <- [
      ApmV5.AgentRegistry, ApmV5.AuditLog, ApmV5.AlertRulesEngine,
      ApmV5.MetricsCollector, ApmV5.SloEngine, ApmV5.EventStream,
      ApmV5.SkillTracker
    ] do
      case module.start_link([]) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        _ -> :ok
      end
    end

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
