defmodule ElixirNawalaWeb.AdminSessionController do
  use ElixirNawalaWeb, :controller

  alias ElixirNawala.Accounts
  alias ElixirNawalaWeb.AdminAuth

  def new(conn, _params) do
    conn
    |> assign(:hide_topbar, true)
    |> assign(:page_title, "Admin Sign In | Elixir Nawala")
    |> render(:new)
  end

  def create(conn, %{"admin" => %{"email" => email, "password" => password}}) do
    case Accounts.authenticate_admin(email, password) do
      {:ok, admin} ->
        conn
        |> AdminAuth.log_in_admin(admin)
        |> put_flash(:info, "Signed in successfully.")
        |> redirect(to: "/admin/dashboard")

      :error ->
        conn
        |> assign(:hide_topbar, true)
        |> assign(:page_title, "Admin Sign In | Elixir Nawala")
        |> put_flash(:error, "Sign-in failed. Please check your email and password.")
        |> render(:new)
    end
  end

  def delete(conn, _params) do
    conn
    |> AdminAuth.log_out_admin()
    |> put_flash(:info, "Signed out successfully.")
    |> redirect(to: "/admin/login")
  end
end
