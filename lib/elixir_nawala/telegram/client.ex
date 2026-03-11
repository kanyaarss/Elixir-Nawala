defmodule ElixirNawala.Telegram.Client do
  @moduledoc false

  alias ElixirNawala.Monitor

  @base_url Application.compile_env(
              :elixir_nawala,
              [__MODULE__, :base_url],
              "https://api.telegram.org"
            )

  def send_message(chat_id, text) when is_binary(chat_id) and is_binary(text) do
    token = bot_token()

    if is_nil(token) or token == "" do
      {:error, :missing_bot_token}
    else
      url = "#{@base_url}/bot#{token}/sendMessage"

      case Req.post(url, json: %{chat_id: chat_id, text: text}) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, extract_message_id(body)}

        {:ok, %{status: status}} when status in 200..299 ->
          {:ok, nil}

        {:ok, %{status: status, body: body}} -> {:error, {:telegram_error, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def delete_message(chat_id, message_id)
      when is_binary(chat_id) and is_integer(message_id) do
    token = bot_token()

    if is_nil(token) or token == "" do
      {:error, :missing_bot_token}
    else
      url = "#{@base_url}/bot#{token}/deleteMessage"

      case Req.post(url, json: %{chat_id: chat_id, message_id: message_id}) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {:telegram_error, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp bot_token do
    env_token = Application.get_env(:elixir_nawala, __MODULE__)[:bot_token]

    settings_token =
      Monitor.list_settings()
      |> Map.get("telegram_bot_token", "")

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

  defp extract_message_id(%{"result" => %{"message_id" => id}}) when is_integer(id), do: id
  defp extract_message_id(%{"result" => %{"message_id" => id}}) when is_binary(id) do
    case Integer.parse(id) do
      {value, _} -> value
      _ -> nil
    end
  end

  defp extract_message_id(_), do: nil
end
