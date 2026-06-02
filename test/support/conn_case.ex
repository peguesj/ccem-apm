defmodule ApmWeb.ConnCase do
  @moduledoc """
  Test case for controller tests requiring a connection.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint ApmWeb.Endpoint

      use ApmWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import ApmWeb.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
