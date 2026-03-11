defmodule ElixirNawala.Monitor do
  import Ecto.Query, warn: false
  alias ElixirNawala.Repo
  alias ElixirNawala.Monitor.{CheckResult, Domain, Notification, Setting, SflinkProfile}
  alias ElixirNawala.Sflink.Client

  @pubsub ElixirNawala.PubSub
  @dashboard_topic "monitor:dashboard"
  @max_sflink_profiles 10

  @settings_defaults %{
    "checker_interval_seconds" => "300",
    "sflink_base_url" => "https://app.sflink.id",
    "sflink_api_token" => "",
    "telegram_bot_token" => "",
    "telegram_group_chat_id" => "",
    "telegram_private_chat_id" => "",
    "telegram_notifications_enabled" => "true",
    "telegram_group_notifications_enabled" => "true",
    "telegram_private_notifications_enabled" => "true",
    "telegram_group_last_message_id" => "",
    "telegram_private_last_message_id" => "",
    "admin_reset_telegram_bot_token" => "",
    "admin_reset_telegram_group_chat_id" => ""
  }

  def list_domains do
    Domain
    |> order_by([d], asc: d.name)
    |> Repo.all()
  end

  def list_sflink_profiles do
    SflinkProfile
    |> order_by([p], asc: p.inserted_at)
    |> Repo.all()
  end

  def max_sflink_profiles, do: @max_sflink_profiles

  def list_active_sflink_tokens do
    SflinkProfile
    |> where([p], p.active == true)
    |> order_by([p], asc: p.inserted_at)
    |> Repo.all()
    |> Enum.map(& &1.api_token)
    |> Enum.uniq()
  end

  def list_active_sflink_profiles do
    SflinkProfile
    |> where([p], p.active == true)
    |> order_by([p], asc: p.inserted_at)
    |> Repo.all()
  end

  def list_add_domain_profiles do
    list_active_sflink_profiles()
    |> Enum.reduce([], fn profile, acc ->
      token = profile.api_token |> to_string() |> String.trim()

      case Client.get_me(token) do
        {:ok, payload} ->
          remaining = extract_domains_remaining(payload)
          limit = extract_domains_limit(payload)
          can_add = is_nil(remaining) or remaining > 0

          if can_add do
            acc ++
              [
                %{
                  id: profile.id,
                  name: profile.name,
                  email: profile.email,
                  domains_remaining: remaining,
                  domains_limit: limit
                }
              ]
          else
            acc
          end

        _ ->
          acc
      end
    end)
  end

  def create_sflink_profile(attrs) when is_map(attrs) do
    if Repo.aggregate(SflinkProfile, :count, :id) >= @max_sflink_profiles do
      {:error, :token_limit}
    else
      token =
        attrs
        |> Map.get("api_token", "")
        |> to_string()
        |> String.trim()

      cond do
        token == "" ->
          {:error, :invalid_token}

        profile_token_taken?(token) ->
          {:error, :duplicate_token}

        true ->
          with {:ok, remote} <- Client.get_me_with_token(token) do
        user = remote.user || %{}
        base_name =
          attrs["name"]
          |> to_string()
          |> String.trim()
          |> case do
            "" -> user["username"] || user["email"] || "SFLINK Profile"
            other -> other
          end

        Repo.transaction(fn ->
          name = unique_profile_name(base_name)

          profile =
            %SflinkProfile{}
            |> SflinkProfile.changeset(%{
              name: name,
              email: user["email"],
              api_token: token,
              active: true
            })
            |> Repo.insert()

          case profile do
            {:ok, record} -> record
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)
        |> case do
          {:ok, profile} -> {:ok, profile}
          {:error, reason} -> {:error, reason}
        end
          end
      end
    end
  end

  def activate_sflink_profile(id) when is_integer(id) do
    Repo.transaction(fn ->
      profile = Repo.get!(SflinkProfile, id)
      {:ok, active_profile} = profile |> SflinkProfile.changeset(%{active: true}) |> Repo.update()
      active_profile
    end)
  end

  def delete_sflink_profile(id) when is_integer(id) do
    Repo.transaction(fn ->
      profile = Repo.get!(SflinkProfile, id)
      is_active = profile.active
      {:ok, _} = Repo.delete(profile)

      if is_active do
        still_has_active =
          SflinkProfile
          |> where([p], p.active == true)
          |> Repo.exists?()

        if not still_has_active do
          upsert_settings(%{
            "sflink_base_url" => "https://app.sflink.id",
            "sflink_api_token" => ""
          })
        end
      end

      :ok
    end)
  end

  def clear_active_sflink_token do
    Repo.transaction(fn ->
      Repo.update_all(SflinkProfile, set: [active: false])

      upsert_settings(%{"sflink_base_url" => "https://app.sflink.id"})
      clear_setting_key("sflink_api_token")

      :ok
    end)
  end

  def list_remote_domains do
    profiles = list_active_sflink_profiles()

    case profiles do
      [] ->
        with_token_fallback(fn token ->
          case Client.list_domains(token) do
            {:ok, domains} when is_list(domains) ->
              {:ok,
               Enum.map(domains, fn item ->
                 remote_id = item["id"]

                 %{
                   id: remote_id,
                   domain: item["domain"] || item["name"],
                   status: item["status"],
                   is_verified: item["is_verified"],
                   created_at: item["created_at"],
                   last_checked: item["last_checked"],
                   check_interval_minutes: item["check_interval_minutes"],
                   source_profile_id: nil,
                   source_profile_name: "Default",
                   domain_key: "default:#{remote_id}"
                 }
               end)}

            error ->
              error
          end
        end)

      _ ->
        {domains, last_error} =
          Enum.reduce(profiles, {[], nil}, fn profile, {acc, error_acc} ->
            case Client.list_domains(profile.api_token) do
              {:ok, remote_domains} when is_list(remote_domains) ->
                mapped =
                  Enum.map(remote_domains, fn item ->
                    remote_id = item["id"]

                    %{
                      id: remote_id,
                      domain: item["domain"] || item["name"],
                      status: item["status"],
                      is_verified: item["is_verified"],
                      created_at: item["created_at"],
                      last_checked: item["last_checked"],
                      check_interval_minutes: item["check_interval_minutes"],
                      source_profile_id: profile.id,
                      source_profile_name: profile.name,
                      domain_key: "#{profile.id}:#{remote_id}"
                    }
                  end)

                {acc ++ mapped, error_acc}

              {:error, reason} ->
                {acc, reason}
            end
          end)

        if domains == [] do
          {:error, last_error || :missing_sflink_token}
        else
          sorted =
            Enum.sort_by(domains, fn rd ->
              {
                to_string(rd.source_profile_name || ""),
                String.downcase(to_string(rd.domain || "")),
                rd.id || 0
              }
            end)

          {:ok, sorted}
        end
    end
  end

  def sync_remote_domains_to_local do
    profiles = list_active_sflink_profiles()

    token_sources =
      case profiles do
        [] -> active_tokens_pool()
        _ -> Enum.map(profiles, & &1.api_token)
      end

    unique_tokens =
      token_sources
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case unique_tokens do
      [] ->
        {:error, :missing_sflink_token}

      _ ->
        {synced_count, last_error} =
          Enum.reduce(unique_tokens, {0, nil}, fn token, {acc_synced, acc_error} ->
            case Client.list_domains(token) do
              {:ok, remote_domains} ->
                synced_for_token =
                  Enum.reduce(remote_domains, 0, fn item, acc ->
                    name = item["domain"] || item["name"]
                    remote_id = item["id"]

                    if is_binary(name) and is_integer(remote_id) do
                      attrs = %{"name" => String.trim(name), "sflink_domain_id" => remote_id}

                      case upsert_remote_domain(attrs) do
                        :ok -> acc + 1
                        _ -> acc
                      end
                    else
                      acc
                    end
                  end)

                {acc_synced + synced_for_token, acc_error}

              {:error, reason} ->
                {acc_synced, reason}
            end
          end)

        if synced_count > 0 do
          {:ok, %{synced: synced_count}}
        else
          {:error, last_error || :missing_sflink_token}
        end
    end
  end

  def live_check_remote_domain_status(remote_domain_id) when is_integer(remote_domain_id) do
    with_token_fallback(fn token -> Client.live_check_status(remote_domain_id, token) end)
    |> maybe_persist_live_remote_status(remote_domain_id)
  end

  def live_check_remote_domains(remote_domains) when is_list(remote_domains) do
    remote_domains
    |> Task.async_stream(
      &live_check_remote_domain_entry/1,
      max_concurrency: 6,
      timeout: 8_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.reduce(%{}, fn
      {:ok, {key, status}}, acc when is_binary(key) and is_binary(status) and status != "" ->
        Map.put(acc, key, status)

      _, acc ->
        acc
    end)
  end

  def live_check_remote_domain_status(remote_domain_id, profile_id)
      when is_integer(remote_domain_id) and is_integer(profile_id) do
    with {:ok, token} <- token_for_active_profile(profile_id) do
      Client.live_check_status(remote_domain_id, token)
    end
    |> maybe_persist_live_remote_status(remote_domain_id)
  end

  def get_remote_profile_stats do
    with_token_fallback(fn token ->
      case Client.get_me(token) do
        {:ok, %{user: user, stats: stats} = payload} ->
          {:ok, %{user: user || %{}, stats: stats || %{}, raw: payload.raw}}

        error ->
          error
      end
    end)
  end

  def get_domain!(id), do: Repo.get!(Domain, id)
  def get_domain(id), do: Repo.get(Domain, id)

  def create_domain(attrs), do: %Domain{} |> Domain.changeset(attrs) |> Repo.insert()

  def create_domain_from_sflink(%{"name" => domain_name} = attrs) when is_binary(domain_name) do
    domain_name = String.trim(domain_name)

    with {:ok, token} <- token_for_domain_creation(attrs),
         {:ok, remote_payload} <- Client.create_domain(domain_name, token) do
      effective_name = remote_payload.domain || domain_name
      remote_id = remote_payload.id

      case Repo.get_by(Domain, name: domain_name) do
        %Domain{} = domain ->
          updated =
            if is_integer(remote_id) and domain.sflink_domain_id != remote_id do
              {:ok, updated_domain} =
                domain
                |> Domain.changeset(%{sflink_domain_id: remote_id})
                |> Repo.update()

              updated_domain
            else
              domain
            end

          {:ok, %{local_domain: updated, sflink: remote_payload}}

        nil ->
          create_attrs =
            attrs
            |> Map.put("name", effective_name)
            |> Map.put("sflink_domain_id", remote_id)

          case create_domain(create_attrs) do
            {:ok, local_domain} -> {:ok, %{local_domain: local_domain, sflink: remote_payload}}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  def delete_domain_from_sflink(local_domain_id) when is_integer(local_domain_id) do
    domain = get_domain!(local_domain_id)

    with_token_fallback(fn token ->
      with {:ok, remote_id} <- resolve_remote_domain_id(domain, token),
           {:ok, remote_result} <- Client.delete_domain(remote_id, token),
           {:ok, _local_deleted} <- Repo.delete(domain) do
        {:ok, %{local_name: domain.name, remote_id: remote_id, sflink: remote_result}}
      end
    end)
  end

  def delete_remote_domain(remote_domain_id) when is_integer(remote_domain_id) do
    with_token_fallback(fn token ->
      with {:ok, remote_result} <- Client.delete_domain(remote_domain_id, token) do
        local_deleted =
          case Repo.get_by(Domain, sflink_domain_id: remote_domain_id) do
            nil ->
              false

            %Domain{} = local_domain ->
              case Repo.delete(local_domain) do
                {:ok, _} -> true
                _ -> false
              end
          end

        {:ok, %{remote_id: remote_domain_id, local_deleted: local_deleted, sflink: remote_result}}
      end
    end)
  end

  def delete_remote_domain(remote_domain_id, profile_id)
      when is_integer(remote_domain_id) and is_integer(profile_id) do
    with {:ok, token} <- token_for_active_profile(profile_id),
         {:ok, remote_result} <- Client.delete_domain(remote_domain_id, token) do
      local_deleted =
        case Repo.get_by(Domain, sflink_domain_id: remote_domain_id) do
          nil ->
            false

          %Domain{} = local_domain ->
            case Repo.delete(local_domain) do
              {:ok, _} -> true
              _ -> false
            end
        end

      {:ok, %{remote_id: remote_domain_id, local_deleted: local_deleted, sflink: remote_result}}
    end
  end

  def list_active_domains do
    Domain
    |> where([d], d.active == true)
    |> order_by([d], asc: d.name)
    |> Repo.all()
  end

  def toggle_domain(domain_id) do
    domain = get_domain!(domain_id)
    domain |> Domain.changeset(%{active: !domain.active}) |> Repo.update()
  end

  def list_settings do
    settings = Repo.all(Setting) |> Map.new(&{&1.key, &1.value})
    Map.merge(@settings_defaults, settings)
  end

  def checker_interval_seconds do
    list_settings()
    |> Map.get("checker_interval_seconds", "300")
    |> case do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {seconds, _} when seconds >= 60 -> seconds
          _ -> 300
        end

      _ ->
        300
    end
  end

  def upsert_settings(attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      Enum.each(attrs, fn {key, value} ->
        case Repo.get_by(Setting, key: key) do
          nil ->
            %Setting{} |> Setting.changeset(%{key: key, value: value}) |> Repo.insert!()

          %Setting{} = setting ->
            setting |> Setting.changeset(%{value: value}) |> Repo.update!()
        end
      end)
    end)
  end

  def create_check_result(attrs), do: %CheckResult{} |> CheckResult.changeset(attrs) |> Repo.insert()

  def record_domain_check(%Domain{} = domain, status, raw_payload, latency_ms, request_id) do
    checked_at = DateTime.utc_now()

    Repo.transaction(fn ->
      {:ok, _check_result} =
        create_check_result(%{
          domain_id: domain.id,
          status: status,
          raw_payload: raw_payload,
          checked_at: checked_at,
          latency_ms: latency_ms,
          request_id: request_id
        })

      {:ok, updated_domain} =
        domain
        |> Domain.changeset(%{last_status: status, last_checked_at: checked_at})
        |> Repo.update()

      %{domain: updated_domain, changed?: domain.last_status != status}
    end)
  end

  def create_notification(attrs), do: %Notification{} |> Notification.changeset(attrs) |> Repo.insert()

  def update_notification_status(notification_id, status) when status in ["sent", "failed"] do
    case Repo.get(Notification, notification_id) do
      nil ->
        :ok

      %Notification{} = notification ->
        attrs =
          if status == "sent",
            do: %{status: status, sent_at: DateTime.utc_now()},
            else: %{status: status}

        notification
        |> Notification.changeset(attrs)
        |> Repo.update()
    end
  end

  def enqueue_domain_status_notifications(%Domain{} = domain, previous_status, new_status) do
    settings = list_settings()

    if should_send_live_telegram?(new_status, settings) do
      checked_at =
        DateTime.utc_now()
        |> DateTime.add(25_200, :second)
        |> Calendar.strftime("%d-%m-%Y %H:%M:%S WIB")

      message = """
      [ALERT LIVE ELIXIR NAWALA]
      Waktu check: #{checked_at}
      Domain: #{domain.name}
      Status sebelumnya: #{String.upcase(to_string(previous_status || "unknown"))}
      Status sekarang: #{String.upcase(to_string(new_status || "unknown"))}
      """

      maybe_queue_telegram(
        :group,
        settings["telegram_group_chat_id"],
        settings["telegram_group_notifications_enabled"],
        domain.id,
        message
      )

      maybe_queue_telegram(
        :private,
        settings["telegram_private_chat_id"],
        settings["telegram_private_notifications_enabled"],
        domain.id,
        message
      )
    else
      :ok
    end
  end

  def enqueue_telegram_notification(target, message) when target in [:group, :private] do
    ElixirNawala.Workers.TelegramMessageWorker.new(%{
      "target" => Atom.to_string(target),
      "message" => message
    })
    |> Oban.insert()
  end

  def enqueue_telegram_summary_notification do
    settings = list_settings()

    if settings["telegram_notifications_enabled"] == "true" and
         ((settings["telegram_group_notifications_enabled"] == "true" and settings["telegram_group_chat_id"] not in [nil, ""]) or
            (settings["telegram_private_notifications_enabled"] == "true" and
               settings["telegram_private_chat_id"] not in [nil, ""])) do
      ElixirNawala.Workers.TelegramSummaryWorker.enqueue()
    else
      :ok
    end
  end

  def enqueue_program_error_notification(message) when is_binary(message) do
    settings = list_settings()

    if settings["telegram_notifications_enabled"] == "true" do
      maybe_queue_telegram(
        :group,
        settings["telegram_group_chat_id"],
        settings["telegram_group_notifications_enabled"],
        nil,
        message
      )

      maybe_queue_telegram(
        :private,
        settings["telegram_private_chat_id"],
        settings["telegram_private_notifications_enabled"],
        nil,
        message
      )
    else
      :ok
    end
  end

  def subscribe_dashboard, do: Phoenix.PubSub.subscribe(@pubsub, @dashboard_topic)

  def broadcast_domain_updated(%Domain{} = domain) do
    Phoenix.PubSub.broadcast(@pubsub, @dashboard_topic, {:domain_updated, domain})
  end

  def broadcast_checker_cycle(summary) when is_map(summary) do
    Phoenix.PubSub.broadcast(@pubsub, @dashboard_topic, {:checker_cycle_finished, summary})
  end

  defp maybe_queue_telegram(_target, _chat_id, enabled, _domain_id, _message) when enabled != "true", do: :ok
  defp maybe_queue_telegram(_target, chat_id, _enabled, _domain_id, _message) when chat_id in [nil, ""], do: :ok

  defp maybe_queue_telegram(target, chat_id, _enabled, domain_id, message) do
    with {:ok, notification} <-
           create_notification(%{
             domain_id: domain_id,
             channel: "telegram_#{target}",
             event_type: "status_changed",
             payload: %{"chat_id" => chat_id, "message" => message},
             status: "queued"
           }) do
      ElixirNawala.Workers.TelegramMessageWorker.new(%{
        "target" => Atom.to_string(target),
        "message" => message,
        "notification_id" => notification.id
      })
      |> Oban.insert()
    end
  end

  defp should_send_live_telegram?(new_status, settings) do
    settings["telegram_notifications_enabled"] == "true" and new_status in ["nawala", "blocked", "down", "error"]
  end

  defp maybe_persist_live_remote_status({:ok, %{status: status}} = result, remote_domain_id)
       when is_integer(remote_domain_id) do
    normalized_status = normalize_live_remote_status(status)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(d in Domain, where: d.sflink_domain_id == ^remote_domain_id)
    |> Repo.update_all(set: [last_status: normalized_status, last_checked_at: now, updated_at: now])

    result
  end

  defp maybe_persist_live_remote_status(result, _remote_domain_id), do: result

  defp normalize_live_remote_status(status) do
    status
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      value when value in ["up", "trusted", "safe", "true"] -> "up"
      value when value in ["blocked", "nawala", "down", "error", "failed", "false", "diblokir"] -> "nawala"
      _ -> "unknown"
    end
  end

  defp resolve_remote_domain_id(%Domain{sflink_domain_id: id}, _token) when is_integer(id), do: {:ok, id}

  defp resolve_remote_domain_id(%Domain{name: domain_name}, token) do
    with {:ok, remote_domains} <- Client.list_domains(token) do
      normalized = String.downcase(domain_name)

      match =
        Enum.find(remote_domains, fn item ->
          remote_name = item["domain"] || item["name"] || item["domain_name"] || ""
          String.downcase(to_string(remote_name)) == normalized
        end)

      case match do
        %{"id" => id} when is_integer(id) -> {:ok, id}
        _ -> {:error, :remote_domain_not_found}
      end
    end
  end

  defp upsert_remote_domain(%{"name" => name, "sflink_domain_id" => remote_id} = attrs) do
    existing =
      Repo.get_by(Domain, sflink_domain_id: remote_id) ||
        Repo.get_by(Domain, name: name)

    case existing do
      nil ->
        case create_domain(attrs) do
          {:ok, _} -> :ok
          _ -> :error
        end

      %Domain{} = domain ->
        update_attrs = %{"name" => name, "sflink_domain_id" => remote_id}

        case domain |> Domain.changeset(update_attrs) |> Repo.update() do
          {:ok, _} -> :ok
          _ -> :error
        end
    end
  end

  defp clear_setting_key(key) when is_binary(key) do
    case Repo.get_by(Setting, key: key) do
      nil -> :ok
      %Setting{} = setting ->
        case Repo.delete(setting) do
          {:ok, _} -> :ok
          _ -> :ok
        end
    end
  end

  defp unique_profile_name(base_name) do
    base =
      base_name
      |> to_string()
      |> String.trim()
      |> case do
        "" -> "SFLINK Profile"
        value -> String.slice(value, 0, 80)
      end

    if profile_name_taken?(base) do
      find_profile_name_suffix(base, 2)
    else
      base
    end
  end

  defp find_profile_name_suffix(base, n) do
    suffix = "-#{n}"
    limit = max(80 - String.length(suffix), 1)
    candidate = String.slice(base, 0, limit) <> suffix

    if profile_name_taken?(candidate) do
      find_profile_name_suffix(base, n + 1)
    else
      candidate
    end
  end

  defp profile_name_taken?(name) do
    SflinkProfile
    |> where([p], p.name == ^name)
    |> Repo.exists?()
  end

  defp profile_token_taken?(token) do
    SflinkProfile
    |> where([p], p.api_token == ^token)
    |> Repo.exists?()
  end

  defp pick_active_token do
    case active_tokens_pool() do
      [token | _] -> {:ok, token}
      _ -> {:error, :missing_sflink_token}
    end
  end

  defp active_tokens_pool do
    settings_token =
      list_settings()
      |> Map.get("sflink_api_token", "")
      |> to_string()
      |> String.trim()

    tokens =
      list_active_sflink_tokens()
      |> Enum.map(&String.trim(to_string(&1)))
      |> Enum.reject(&(&1 == ""))

    ([settings_token | tokens] ++ tokens)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp with_token_fallback(fun) when is_function(fun, 1) do
    case active_tokens_pool() do
      [] ->
        {:error, :missing_sflink_token}

      tokens ->
        Enum.reduce_while(tokens, {:error, :missing_sflink_token}, fn token, _acc ->
          case fun.(token) do
            {:ok, _} = ok -> {:halt, ok}
            {:error, _} = error -> {:cont, error}
            other -> {:cont, {:error, {:invalid_sflink_response, other}}}
          end
        end)
    end
  end

  defp token_for_domain_creation(attrs) when is_map(attrs) do
    profile_id =
      attrs
      |> Map.get("profile_id", "")
      |> to_string()
      |> String.trim()

    case profile_id do
      "" ->
        {:error, :missing_profile_selection}

      value ->
        case Integer.parse(value) do
          {id, _} -> token_for_active_profile(id)
          _ -> {:error, :invalid_profile_selection}
        end
    end
  end

  defp token_for_active_profile(profile_id) when is_integer(profile_id) do
    case Repo.get(SflinkProfile, profile_id) do
      %SflinkProfile{active: true, api_token: token} when is_binary(token) ->
        trimmed = String.trim(token)
        if trimmed == "", do: {:error, :missing_sflink_token}, else: {:ok, trimmed}

      %SflinkProfile{} ->
        {:error, :inactive_profile}

      nil ->
        {:error, :profile_not_found}
    end
  end

  defp live_check_remote_domain_entry(remote_domain) when is_map(remote_domain) do
    key = remote_domain_key(remote_domain)
    remote_id = remote_domain[:id]
    profile_id = remote_domain[:source_profile_id]

    result =
      cond do
        is_integer(remote_id) and is_integer(profile_id) ->
          live_check_remote_domain_status(remote_id, profile_id)

        is_integer(remote_id) ->
          live_check_remote_domain_status(remote_id)

        true ->
          {:error, :invalid_remote_id}
      end

    case result do
      {:ok, payload} ->
        status =
          payload
          |> Map.get(:status, "")
          |> to_string()
          |> String.downcase()

        {key, status}

      _ ->
        {key, ""}
    end
  end

  defp live_check_remote_domain_entry(_), do: {"default:unknown", ""}

  defp remote_domain_key(remote_domain) when is_map(remote_domain) do
    remote_domain[:domain_key] ||
      "#{Map.get(remote_domain, :source_profile_id, "default")}:#{Map.get(remote_domain, :id, "unknown")}"
  end

  defp extract_domains_remaining(%{raw: raw, stats: stats}) do
    first_integer([
      get_in(raw || %{}, ["data", "limits", "domains_remaining"]),
      get_in(raw || %{}, ["data", "limit", "domains_remaining"]),
      get_in(raw || %{}, ["data", "domains_remaining"]),
      get_in(raw || %{}, ["limits", "domains_remaining"]),
      get_in(stats || %{}, ["domains_remaining"]),
      get_in(stats || %{}, ["remaining_domains"]),
      get_in(stats || %{}, ["remaining"])
    ])
  end

  defp extract_domains_remaining(_), do: nil

  defp extract_domains_limit(%{raw: raw, stats: stats}) do
    first_integer([
      get_in(raw || %{}, ["data", "limits", "max_domains"]),
      get_in(raw || %{}, ["data", "limit", "max_domains"]),
      get_in(raw || %{}, ["data", "limits", "domain_limit"]),
      get_in(raw || %{}, ["limits", "max_domains"]),
      get_in(stats || %{}, ["max_domains"]),
      get_in(stats || %{}, ["domain_limit"]),
      get_in(stats || %{}, ["domains_limit"])
    ])
  end

  defp extract_domains_limit(_), do: nil

  defp first_integer(values) when is_list(values) do
    Enum.find_value(values, fn value ->
      case value do
        int when is_integer(int) ->
          int

        float when is_float(float) ->
          trunc(float)

        binary when is_binary(binary) ->
          case Integer.parse(String.trim(binary)) do
            {int, _} -> int
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end
end
