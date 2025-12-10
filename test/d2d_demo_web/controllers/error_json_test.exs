defmodule D2dDemoWeb.ErrorJSONTest do
  use D2dDemoWeb.ConnCase, async: true

  test "renders 404" do
    assert D2dDemoWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert D2dDemoWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
