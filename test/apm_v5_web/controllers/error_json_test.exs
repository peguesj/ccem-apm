defmodule ApmV5Web.ErrorJSONTest do
  use ApmV5Web.ConnCase, async: true

  test "renders 404" do
    assert ApmV5Web.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert ApmV5Web.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
