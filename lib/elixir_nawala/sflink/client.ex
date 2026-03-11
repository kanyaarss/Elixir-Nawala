defmodule ElixirNawala.Sflink.Client do
  @moduledoc false

  @statuses ~w(up down nawala unknown error)
  @timeout 10_000
  @request_opts [receive_timeout: @timeout]

  def fetch_domain_status(domain_name, token \\ nil) when is_binary(domain_name) do
    request_id = Ecto.UUID.generate()
    started_at = System.monotonic_time(:millisecond)

    with {:ok, response} <- request_status(domain_name, token),
         {:ok, status} <- normalize_status(response) do
      {:ok,
       %{
         status: status,
         raw_payload: response,
         latency_ms: System.monotonic_time(:millisecond) - started_at,
         request_id: request_id
       }}
    else
      {:error, reason} ->
        {:ok,
         %{
           status: "error",
           raw_payload: %{"error" => inspect(reason), "domain" => domain_name},
           latency_ms: System.monotonic_time(:millisecond) - started_at,
           request_id: request_id
         }}
    end
  end

  def create_domain(domain_name, token \\ nil) when is_binary(domain_name) do
    url = with_api_key("#{api_base_url()}/domains", token)
    payload = %{"domain" => domain_name}

    case request(:post, url, [json: payload, token: token]) do
      {:ok, %{status: code, body: body}} when code in 200..299 ->
        normalize_create_domain_response(body)

      {:ok, %{status: code, body: body}} ->
        {:error, {:http_error, code, error_message(body), body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_domains(token \\ nil) do
    url = with_api_key("#{api_base_url()}/domains", token)

    case request(:get, url, [token: token]) do
      {:ok, %{status: code, body: body}} when code in 200..299 ->
        normalize_list_domains_response(body)

      {:ok, %{status: code, body: body}} ->
        {:error, {:http_error, code, error_message(body), body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_me(token \\ nil) do
    url = with_api_key("#{api_base_url()}/me", token)

    case request(:get, url, [token: token]) do
      {:ok, %{status: code, body: body}} when code in 200..299 ->
        normalize_me_response(body)

      {:ok, %{status: code, body: body}} ->
        {:error, {:http_error, code, error_message(body), body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_me_with_token(token) when is_binary(token) do
    trimmed = String.trim(token)
    url = append_query("#{api_base_url()}/me", "api_key", trimmed)
    headers = [{"authorization", "Bearer #{trimmed}"}, {"x-api-key", trimmed}]

    case request(:get, url, [headers: headers]) do
      {:ok, %{status: code, body: body}} when code in 200..299 ->
        normalize_me_response(body)

      {:ok, %{status: code, body: body}} ->
        {:error, {:http_error, code, error_message(body), body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def live_check_status(remote_domain_id, token \\ nil) when is_integer(remote_domain_id) do
    url = with_api_key("#{api_base_url()}/domains/#{remote_domain_id}/status", token)

    case request(:get, url, [token: token]) do
      {:ok, %{status: code, body: body}} when code in 200..299 ->
        normalize_live_status_response(body)

      {:ok, %{status: code, body: body}} ->
        {:error, {:http_error, code, error_message(body), body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def delete_domain(remote_domain_id, token \\ nil) when is_integer(remote_domain_id) do
    url = with_api_key("#{api_base_url()}/domains/#{remote_domain_id}", token)

    case request(:delete, url, [token: token]) do
      {:ok, %{status: code, body: body}} when code in 200..299 ->
        {:ok, %{id: remote_domain_id, message: body["message"] || "Domain deleted.", raw: body}}

      {:ok, %{status: code, body: body}} ->
        {:error, {:http_error, code, error_message(body), body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_status(domain_name, token) do
    base_url = api_base_url()
    encoded_name = URI.encode(domain_name)

    path_url = with_api_key("#{base_url}/domains/#{encoded_name}/status", token)

    case req_get(path_url, token) do
      {:ok, %{status: code, body: body}} when code in 200..299 ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        req_get(with_api_key("#{base_url}/domains/status?domain=#{encoded_name}", token), token)
        |> parse_http_response()

      other ->
        parse_http_response(other)
    end
  end

  defp parse_http_response({:ok, %{status: code, body: body}}) when code in 200..299, do: {:ok, body}
  defp parse_http_response({:ok, %{status: code, body: body}}), do: {:error, {:http_error, code, body}}
  defp parse_http_response({:error, reason}), do: {:error, reason}

  defp req_get(url, token) do
    request(:get, url, [token: token])
  end

  defp request_headers(token) do
    case token || api_token() do
      nil -> []
      "" -> []
      token -> [{"authorization", "Bearer #{token}"}, {"x-api-key", token}]
    end
  end

  defp api_base_url do
    setting_base = ElixirNawala.Monitor.list_settings()["sflink_base_url"]
    normalized =
      if is_binary(setting_base) and setting_base != "" do
        setting_base
        |> String.trim()
        |> String.trim_trailing("/")
      else
        "https://app.sflink.id"
      end

    normalized =
      case normalized do
        "https://sflink.id" -> "https://app.sflink.id"
        "http://sflink.id" -> "https://app.sflink.id"
        _ -> normalized
      end

    if String.ends_with?(normalized, "/api/v1"), do: normalized, else: "#{normalized}/api/v1"
  end

  defp with_api_key(url, token) do
    case token || api_token() do
      nil -> url
      "" -> url
      token -> append_query(url, "api_key", token)
    end
  end

  defp api_token do
    env_token = Application.get_env(:elixir_nawala, __MODULE__)[:api_token]
    settings_token = ElixirNawala.Monitor.list_settings()["sflink_api_token"]

    [settings_token, env_token]
    |> Enum.find_value(fn token ->
      case token do
        value when is_binary(value) ->
          trimmed = String.trim(value)
          if trimmed == "", do: nil, else: trimmed

        _ ->
          nil
      end
    end)
  end

  defp append_query(url, key, value) do
    uri = URI.parse(url)
    decoded = URI.decode_query(uri.query || "")
    new_query = decoded |> Map.put(key, value) |> URI.encode_query()
    URI.to_string(%URI{uri | query: new_query})
  end

  defp normalize_status(payload) when is_map(payload) do
    status =
      payload["status"] ||
        payload["domain_status"] ||
        payload["result"] ||
        get_in(payload, ["data", "status"])

    normalized =
      status
      |> to_string()
      |> String.downcase()

    if normalized in @statuses do
      {:ok, normalized}
    else
      {:ok, "unknown"}
    end
  rescue
    _ -> {:error, :invalid_payload}
  end

  defp normalize_status(_), do: {:error, :invalid_payload}

  defp normalize_create_domain_response(%{"success" => true, "data" => data} = body) when is_map(data) do
    {:ok,
     %{
       id: data["id"],
       domain: data["domain"],
       message: body["message"] || "Domain added successfully.",
       raw: body
     }}
  end

  defp normalize_create_domain_response(%{"success" => false} = body) do
    {:error, {:sflink_error, error_message(body), body}}
  end

  defp normalize_create_domain_response(%{"data" => data} = body) when is_map(data) do
    {:ok,
     %{
       id: data["id"],
       domain: data["domain"],
       message: body["message"] || "Domain added successfully.",
       raw: body
     }}
  end

  defp normalize_create_domain_response(body) when is_map(body) do
    {:ok, %{id: nil, domain: nil, message: body["message"] || "Domain added.", raw: body}}
  end

  defp normalize_create_domain_response(body), do: {:error, {:invalid_response, body}}

  defp normalize_list_domains_response(%{"success" => true, "data" => %{"domains" => domains}})
       when is_list(domains) do
    {:ok, domains}
  end

  defp normalize_list_domains_response(%{"data" => %{"domains" => domains}})
       when is_list(domains) do
    {:ok, domains}
  end

  defp normalize_list_domains_response(body), do: {:error, {:invalid_response, body}}

  defp normalize_live_status_response(%{"success" => true, "data" => data} = body)
       when is_map(data) do
    status = extract_live_status(data, body)
    {:ok, %{status: to_string(status), raw: body}}
  end

  defp normalize_live_status_response(%{"data" => data} = body) when is_map(data) do
    status = extract_live_status(data, body)
    {:ok, %{status: to_string(status), raw: body}}
  end

  defp normalize_live_status_response(body) when is_map(body) do
    status = extract_live_status(%{}, body)
    {:ok, %{status: to_string(status), raw: body}}
  end

  defp normalize_live_status_response(body), do: {:error, {:invalid_response, body}}

  defp normalize_me_response(%{"success" => true, "data" => data} = body) when is_map(data) do
    {:ok, %{user: extract_user(data), stats: extract_stats(data), raw: body}}
  end

  defp normalize_me_response(%{"data" => data} = body) when is_map(data) do
    {:ok, %{user: extract_user(data), stats: extract_stats(data), raw: body}}
  end

  defp normalize_me_response(body) when is_map(body) do
    {:ok, %{user: extract_user(body), stats: extract_stats(body), raw: body}}
  end

  defp normalize_me_response(body), do: {:error, {:invalid_response, body}}

  defp error_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(body), do: inspect(body)

  defp extract_live_status(data, body) do
    cond do
      is_binary(data["status"]) -> data["status"]
      is_binary(data["domain_status"]) -> data["domain_status"]
      is_binary(data["nawala_status"]) -> String.downcase(data["nawala_status"])
      data["is_blocked"] == true -> "nawala"
      data["is_safe"] == true -> "up"
      is_binary(body["status"]) -> body["status"]
      is_binary(body["domain_status"]) -> body["domain_status"]
      true -> "unknown"
    end
  end

  defp extract_user(data) do
    cond do
      is_map(data["user"]) -> data["user"]
      is_map(data["profile"]) -> data["profile"]
      true -> data
    end
  end

  defp extract_stats(data) do
    cond do
      is_map(data["stats"]) -> data["stats"]
      is_map(data["statistics"]) -> data["statistics"]
      true -> %{}
    end
  end

  defp request(method, url, extra_opts \\ []) do
    token = Keyword.get(extra_opts, :token)
    custom_headers = Keyword.get(extra_opts, :headers)
    opts_without_headers =
      extra_opts
      |> Keyword.delete(:headers)
      |> Keyword.delete(:token)

    opts =
      @request_opts
      |> Keyword.merge(opts_without_headers)
      |> Keyword.put(:headers, custom_headers || request_headers(token))

    case Req.request(Keyword.merge(opts, method: method, url: url)) do
      {:ok, _} = ok ->
        ok

      {:error, %Req.TransportError{reason: :nxdomain}} ->
        Req.request(Keyword.merge(opts, method: method, url: url))

      {:error, reason} ->
        {:error, reason}
    end
  end
end
