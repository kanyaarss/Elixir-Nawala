defmodule ElixirNawalaWeb.PageController do
  use ElixirNawalaWeb, :controller

  def home(conn, _params) do
    conn
    |> assign(:hide_topbar, true)
    |> assign(:home_gateway, true)
    |> assign(:page_title, "Elixir Nawala")
    |> render(:home)
  end
end
