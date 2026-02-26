defmodule ApmV4Web.PageController do
  use ApmV4Web, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
