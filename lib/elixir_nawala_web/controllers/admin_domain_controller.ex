defmodule ElixirNawalaWeb.AdminDomainController do
  use ElixirNawalaWeb, :controller

  alias ElixirNawala.Monitor

  def create(conn, %{"domain" => params}) do
    case Monitor.create_domain_from_sflink(params) do
      {:ok, %{local_domain: local_domain, sflink: sflink}} ->
        label = sflink.domain || local_domain.name

        conn
        |> put_flash(:info, "SFLINK OK: #{label} (id: #{sflink.id || "-"})")
        |> redirect(to: "/admin/dashboard")

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(:error, "Gagal menambahkan domain. Pastikan format domain dan profile sudah benar.")
        |> redirect(to: "/admin/dashboard")

      {:error, {:http_error, code, message, _body}} ->
        _ = {code, message}
        conn
        |> put_flash(:error, "Gagal terhubung ke layanan SFLINK. Silakan coba lagi beberapa saat lagi.")
        |> redirect(to: "/admin/dashboard")

      {:error, {:sflink_error, message, _body}} ->
        _ = message
        conn
        |> put_flash(:error, "Permintaan ditolak oleh SFLINK. Periksa API token dan profile yang digunakan.")
        |> redirect(to: "/admin/dashboard")

      {:error, reason} ->
        _ = reason
        conn
        |> put_flash(:error, "Gagal memproses permintaan penambahan domain.")
        |> redirect(to: "/admin/dashboard")
    end
  end

  def delete(conn, %{"id" => id}) do
    case Integer.parse(id) do
      {domain_id, _} ->
        case Monitor.delete_domain_from_sflink(domain_id) do
          {:ok, %{local_name: name, remote_id: remote_id}} ->
            conn
            |> put_flash(:info, "Domain #{name} deleted (SFLINK id: #{remote_id}).")
            |> redirect(to: "/admin/dashboard")

          {:error, :remote_domain_not_found} ->
            conn
            |> put_flash(:error, "Domain tidak ditemukan pada layanan SFLINK.")
            |> redirect(to: "/admin/dashboard")

          {:error, _reason} ->
            conn
            |> put_flash(:error, "Gagal menghapus domain. Silakan coba lagi.")
            |> redirect(to: "/admin/dashboard")
        end

      :error ->
        conn
        |> put_flash(:error, "ID domain tidak valid.")
        |> redirect(to: "/admin/dashboard")
    end
  end
end
