defmodule D2dDemoWeb.PageController do
  use D2dDemoWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
