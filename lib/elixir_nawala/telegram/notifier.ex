defmodule ElixirNawala.Telegram.Notifier do
  alias ElixirNawala.Monitor
  alias ElixirNawala.Telegram.Client

  def send_test_message(:group, text), do: deliver("telegram_group_chat_id", text)
  def send_test_message(:private, text), do: deliver("telegram_private_chat_id", text)

  def send_domain_status(domain_name, status) do
    msg = "[Elixir Nawala] #{domain_name} => #{status}"
    with :ok <- maybe_deliver(:group, msg), :ok <- maybe_deliver(:private, msg), do: :ok
  end

  def send_periodic_summary do
    domains = Monitor.list_domains()
    timestamp = jakarta_time_now()
    remote_statuses = remote_status_context()

    total = length(domains)
    blocked = Enum.count(domains, &(resolved_status_label(&1, remote_statuses) == "BLOCKED"))

    header = """
    [Elixir Nawala]
    Waktu check: #{timestamp}
    Total domain: #{total}
    Blocked: #{blocked}
    """

    lines =
      domains
      |> Enum.sort_by(&String.downcase(&1.name))
      |> Enum.map(fn domain ->
        status = resolved_status_label(domain, remote_statuses)
        "- #{domain.name} | #{status_with_emoji(status)}"
      end)

    message =
      if lines == [] do
        "#{header}\n- Belum ada domain."
      else
        Enum.join([header, Enum.join(lines, "\n")], "\n")
      end

    with :ok <- maybe_deliver_replace(:group, message),
         :ok <- maybe_deliver_replace(:private, message),
         do: :ok
  end

  defp maybe_deliver(target, text) when target in [:group, :private] do
    settings = Monitor.list_settings()
    key = chat_key(target)
    enabled_key = enabled_key(target)

    if settings["telegram_notifications_enabled"] == "true" and settings[enabled_key] == "true" and settings[key] != "" do
      case Client.send_message(settings[key], text) do
        {:ok, _} -> :ok
        other -> other
      end
    else
      :ok
    end
  end

  defp maybe_deliver_replace(target, text) when target in [:group, :private] do
    settings = Monitor.list_settings()
    chat_id_key = chat_key(target)
    enabled_key = enabled_key(target)
    last_message_key = last_message_key(target)
    chat_id = settings[chat_id_key]

    if settings["telegram_notifications_enabled"] == "true" and settings[enabled_key] == "true" and chat_id not in [nil, ""] do
      _ =
        settings[last_message_key]
        |> parse_message_id()
        |> maybe_delete_previous(chat_id)

      case Client.send_message(chat_id, text) do
        {:ok, message_id} ->
          if is_integer(message_id) do
            Monitor.upsert_settings(%{last_message_key => Integer.to_string(message_id)})
          end

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp deliver(key, text) do
    chat_id = Monitor.list_settings()[key]

    if chat_id in [nil, ""] do
      {:error, :missing_chat_id}
    else
      case Client.send_message(chat_id, text) do
        {:ok, _} -> :ok
        other -> other
      end
    end
  end

  defp chat_key(:group), do: "telegram_group_chat_id"
  defp chat_key(:private), do: "telegram_private_chat_id"

  defp enabled_key(:group), do: "telegram_group_notifications_enabled"
  defp enabled_key(:private), do: "telegram_private_notifications_enabled"

  defp last_message_key(:group), do: "telegram_group_last_message_id"
  defp last_message_key(:private), do: "telegram_private_last_message_id"

  defp jakarta_time_now do
    DateTime.utc_now()
    |> DateTime.add(25_200, :second)
    |> Calendar.strftime("%d-%m-%Y %H:%M:%S WIB")
  end

  defp remote_status_context do
    case Monitor.list_remote_domains() do
      {:ok, remote_domains} ->
        remote_domains
        |> Enum.reduce(%{}, fn rd, acc ->
          domain_name =
            rd.domain
            |> to_string()
            |> String.trim()
            |> String.downcase()

          if domain_name == "" do
            acc
          else
            list_status = rd.status |> to_string() |> String.downcase()
            Map.update(
              acc,
              domain_name,
              list_status,
              fn existing ->
                # Keep the most severe status per domain if duplicated across profiles.
                pick_more_severe_status(existing, list_status)
              end
            )
          end
        end)

      _ ->
        %{}
    end
  end

  defp resolved_status_label(domain, remote_statuses) do
    local_status = domain.last_status |> to_string() |> String.downcase()

    remote_status =
      domain.name
      |> to_string()
      |> String.downcase()
      |> then(&Map.get(remote_statuses, &1, ""))

    local_bucket = status_bucket(local_status)
    remote_bucket = status_bucket(remote_status)

    cond do
      local_bucket == :blocked or remote_bucket == :blocked ->
        "BLOCKED"

      local_bucket == :trusted or remote_bucket == :trusted ->
        "TRUSTED"

      true ->
        "BLOCKED"
    end
  end

  defp pick_more_severe_status(existing, incoming) do
    case {status_bucket(existing), status_bucket(incoming)} do
      {:blocked, _} -> existing
      {_, :blocked} -> incoming
      {:trusted, _} -> existing
      {_, :trusted} -> incoming
      _ -> incoming
    end
  end

  defp status_bucket(status) do
    cond do
      status in ["up", "true", "trusted", "safe", "aman"] ->
        :trusted

      status in ["down", "false", "nawala", "blocked", "diblokir", "error", "failed"] ->
        :blocked

      true ->
        :unknown
    end
  end

  defp status_with_emoji("BLOCKED"), do: "❌ BLOCKED"
  defp status_with_emoji("TRUSTED"), do: "✅ TRUSTED"
  defp status_with_emoji(other), do: to_string(other)

  defp parse_message_id(value) when is_integer(value), do: value

  defp parse_message_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {id, _} -> id
      _ -> nil
    end
  end

  defp parse_message_id(_), do: nil

  defp maybe_delete_previous(nil, _chat_id), do: :ok

  defp maybe_delete_previous(message_id, chat_id) when is_integer(message_id) and is_binary(chat_id) do
    case Client.delete_message(chat_id, message_id) do
      :ok -> :ok
      _ -> :ok
    end
  end
end
