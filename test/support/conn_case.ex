defmodule ApmV5Web.ConnCase do
  @moduledoc """
  Test case for controller tests requiring a connection.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint ApmV5Web.Endpoint

      use ApmV5Web, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import ApmV5Web.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
