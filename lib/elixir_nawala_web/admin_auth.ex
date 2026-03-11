defmodule ElixirNawalaWeb.AdminAuth do
  import Plug.Conn
  import Phoenix.Controller

  alias ElixirNawala.Accounts

  def log_in_admin(conn, admin) do
    conn
    |> renew_session()
    |> put_session(:admin_id, admin.id)
end
  def log_out_admin(conn) do
    configure_session(conn, drop: true)
  end

  def fetch_current_admin(conn, _opts) do
    admin = if admin_id = get_session(conn, :admin_id), do: Accounts.get_admin(admin_id), else: nil
    assign(conn, :current_admin, admin)
  end

  def require_authenticated_admin(conn, _opts) do
    if conn.assigns[:current_admin] do
      conn
    else
      conn
      |> put_flash(:error, "Sesi admin tidak ditemukan atau sudah berakhir. Silakan login kembali.")
      |> redirect(to: "/admin/login")
      |> halt()
    end
  end

  def on_mount(:require_authenticated_admin, _params, session, socket) do
    admin =
      if admin_id = session["admin_id"] do
        Accounts.get_admin(admin_id)
      end

    if admin do
      {:cont, Phoenix.Component.assign(socket, :current_admin, admin)}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "Sesi admin tidak valid. Silakan login kembali.")
       |> Phoenix.LiveView.redirect(to: "/admin/login")}
    end
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
