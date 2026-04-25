defmodule KiroCockpitWeb.PageController do
  use KiroCockpitWeb, :controller

  def home(conn, _params) do
    render(conn, :home, layout: false)
  end
end
