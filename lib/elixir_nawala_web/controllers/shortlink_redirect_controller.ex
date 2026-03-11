defmodule ElixirNawalaWeb.ShortlinkRedirectController do
  use ElixirNawalaWeb, :controller

  alias ElixirNawala.Shortlink

  def show(conn, %{"slug" => slug}) do
    with {:ok, short_link} <- Shortlink.get_active_by_slug(slug),
         :ok <- Shortlink.record_click(short_link, click_metadata(conn)) do
      destination_url = Shortlink.resolve_destination_url(short_link)

      conn
      |> put_status(short_link.redirect_type)
      |> redirect(external: destination_url)
    else
      _ ->
        send_resp(conn, 404, "Not found")
    end
  end

  defp click_metadata(conn) do
    %{
      ip_address: ip_to_string(conn.remote_ip),
      user_agent: header_value(conn, "user-agent"),
      referrer: header_value(conn, "referer")
    }
  end

  defp header_value(conn, key) do
    conn
    |> get_req_header(key)
    |> List.first()
  end

  defp ip_to_string(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, _reason} -> nil
      value -> to_string(value)
    end
  end

  defp ip_to_string(other) when is_binary(other), do: String.trim(other)
  defp ip_to_string(_other), do: nil
end
