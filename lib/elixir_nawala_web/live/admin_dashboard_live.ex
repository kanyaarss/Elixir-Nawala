defmodule ElixirNawalaWeb.AdminDashboardLive do
  use ElixirNawalaWeb, :live_view
  import Ecto.Query, warn: false

  alias ElixirNawala.Accounts
  alias ElixirNawala.Monitor
  alias ElixirNawala.Monitor.CheckResult
  alias ElixirNawala.Repo
  alias ElixirNawala.Shortlink
  alias ElixirNawala.Shortlink.ShortLinkClick
  alias ElixirNawala.Telegram.Notifier
  @api_time_offset_seconds 25_200
  @home_time_ranges %{"1d" => "1 Hari", "7d" => "7 Hari", "1m" => "1 Bulan", "1y" => "1 Tahun"}

  on_mount {ElixirNawalaWeb.AdminAuth, :require_authenticated_admin}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Monitor.subscribe_dashboard()
      :timer.send_interval(1_000, :status_tick)
    end

    initial_page = page_from_action(socket.assigns.live_action)
    domains = Monitor.list_domains()
    settings = Monitor.list_settings()

    shortlink_defaults = Shortlink.new_short_link_form_defaults(shortlink_available_domain_names(domains, []))

    {:ok,
     socket
     |> assign(:page_title, page_title(initial_page))
     |> assign_domains(domains)
     |> assign(:settings, settings)
     |> assign(:add_domain_profiles, [])
     |> assign(:domain_form, to_form(%{"name" => "", "profile_id" => ""}, as: :domain))
     |> assign(:settings_form, to_form(settings, as: :settings))
     |> assign(:test_message, "[Elixir Nawala] Test notifikasi Telegram")
     |> assign(:last_cycle_info, nil)
     |> assign(:current_page, initial_page)
     |> assign(:remote_domains, [])
     |> assign(:remote_statuses, %{})
     |> assign(:sflink_profile, nil)
     |> assign(:sflink_profiles, [])
     |> assign(:max_sflink_profiles, Monitor.max_sflink_profiles())
     |> assign(:list_domain_query, "")
     |> assign(:sflink_profile_form, to_form(%{"name" => "", "api_token" => ""}, as: :sflink_profile))
     |> assign(:status_clock, DateTime.utc_now())
     |> assign(:next_refresh_seconds, 20)
     |> assign(:home_next_refresh_seconds, 30)
     |> assign(:sidebar_collapsed, false)
     |> assign(:sidebar_open, false)
     |> assign(:domain_menu_open, false)
     |> assign(:shortlink_menu_open, false)
     |> assign(:admin_menu_open, false)
     |> assign(:shortlink_form, to_form(shortlink_defaults, as: :shortlink))
     |> assign(:shortlink_list, [])
     |> assign(:shortlink_query, "")
     |> assign(:shortlink_stats, %{})
     |> assign(:shortlink_recent_clicks, [])
     |> assign(:shortlink_rotator_query, "")
     |> assign(:shortlink_rotator_list, [])
     |> assign(:shortlink_rotator_links, [])
     |> assign(:rotator_fallback_domains, [])
     |> assign(:rotator_form, to_form(Shortlink.new_rotator_form_defaults(), as: :rotator))
     |> assign(:rotator_modal_open, false)
     |> assign(:rotator_modal_link, nil)
     |> assign(:rotator_primary_form, to_form(rotator_primary_form_defaults(), as: :rotator_primary))
     |> assign(:admin_manager_change_form, admin_manager_change_form())
     |> assign(:admin_manager_reset_settings_form, admin_manager_reset_settings_form(settings))
     |> assign(:home_time_range, "7d")
     |> assign(:home_analytics, %{})
     |> assign_remote_domains()
     |> assign_home_analytics("7d")}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    page = page_from_action(socket.assigns.live_action)

    socket =
      socket
      |> assign(:current_page, page)
      |> assign(:page_title, page_title(page))
      |> assign(:domain_menu_open, page in [:add_domain, :list_domain, :status_domain])
      |> assign(:shortlink_menu_open, page in [:shortlink_create, :shortlink_list, :shortlink_stats, :shortlink_rotator])
      |> assign(:admin_menu_open, page in [:profile, :admin_manager])

    socket =
      case page do
        :list_domain ->
          socket
          |> sync_remote_domains()
          |> assign_domains(Monitor.list_domains())
          |> assign_remote_domains()
          |> live_check_all_remote_domains()

        :status_domain ->
          socket
          |> assign_remote_domains()
          |> live_check_all_remote_domains()
          |> assign_next_refresh_seconds()

        :add_domain ->
          socket
          |> assign_add_domain_profiles()

        :profile ->
          socket
          |> assign_sflink_profile()
          |> assign(:sflink_profiles, Monitor.list_sflink_profiles())

        :admin_manager ->
          socket
          |> assign(:admin_manager_change_form, admin_manager_change_form())
          |> assign(:admin_manager_reset_settings_form, admin_manager_reset_settings_form(socket.assigns.settings))

        :home ->
          socket
          |> assign_remote_domains(false)
          |> live_check_all_remote_domains()
          |> assign(:home_next_refresh_seconds, 30)
          |> assign_home_analytics(socket.assigns.home_time_range || "7d")

        :telegram ->
          settings = Monitor.list_settings()

          socket
          |> assign(:settings, settings)
          |> assign(:settings_form, to_form(settings, as: :settings))

        :shortlink_create ->
          socket
          |> assign_remote_domains(false)
          |> assign(
            :shortlink_form,
            to_form(
              Shortlink.new_short_link_form_defaults(
                shortlink_available_domain_names(socket.assigns.domains, socket.assigns.remote_domains)
              ),
              as: :shortlink
            )
          )

        :shortlink_list ->
          socket
          |> assign_shortlink_list()

        :shortlink_stats ->
          socket
          |> assign_shortlink_stats()

        :shortlink_rotator ->
          socket
          |> sync_remote_domains()
          |> assign_domains(Monitor.list_domains())
          |> assign_remote_domains(false)
          |> live_check_all_remote_domains()
          |> assign_shortlink_rotator_data()
          |> assign(:rotator_form, to_form(Shortlink.new_rotator_form_defaults(), as: :rotator))

        _ ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("create_domain", %{"domain" => params}, socket) do
    case Monitor.create_domain_from_sflink(params) do
      {:ok, %{local_domain: local_domain, sflink: sflink}} ->
        domains = Monitor.list_domains()
        socket = assign_add_domain_profiles(socket)
        default_profile_id = default_add_domain_profile_id(socket.assigns.add_domain_profiles)

        {:noreply,
         socket
         |> put_flash(:info, "SFLINK OK: #{sflink.domain || local_domain.name} (id: #{sflink.id || "-"})")
         |> assign_domains(domains)
         |> assign(:domain_form, to_form(%{"name" => "", "profile_id" => default_profile_id}, as: :domain))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")
         |> assign(:domain_form, to_form(changeset, as: :domain))}

      {:error, :missing_profile_selection} ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}

      {:error, :invalid_profile_selection} ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}

      {:error, :inactive_profile} ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}

      {:error, :profile_not_found} ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}

      {:error, reason} ->
        _ = format_reason(reason)
        {:noreply, socket |> put_flash(:error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}
    end
  end

  def handle_event("toggle_domain", %{"id" => id}, socket) do
    with {:ok, domain_id} <- parse_id_param(id),
         {:ok, _domain} <- Monitor.toggle_domain(domain_id) do
      domains = Monitor.list_domains()
      {:noreply, socket |> put_flash(:info, "Status domain diperbarui.") |> assign_domains(domains)}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}
    end
  end

  def handle_event("delete_domain", %{"id" => id}, socket) do
    with {:ok, domain_id} <- parse_id_param(id),
         {:ok, %{local_name: name, remote_id: remote_id}} <- Monitor.delete_domain_from_sflink(domain_id) do
      {:noreply,
       socket
       |> put_flash(:info, "Domain #{name} deleted (SFLINK id: #{remote_id}).")
       |> assign_domains(Monitor.list_domains())}
    else
      {:error, :remote_domain_not_found} ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}
    end
  end

  def handle_event("refresh_remote_domains", _params, socket) do
    {:noreply,
     socket
     |> assign(:status_clock, DateTime.utc_now())
     |> assign_remote_domains()
     |> live_check_all_remote_domains()
     |> assign_next_refresh_seconds()}
  end

  def handle_event("sync_remote_domains", _params, socket) do
    case Monitor.sync_remote_domains_to_local() do
      {:ok, %{synced: count}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Sync selesai. #{count} domain dari SFLINK diproses.")
         |> assign_domains(Monitor.list_domains())
         |> assign_remote_domains()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}
    end
  end

  def handle_event("search_domain_list", %{"domain_search" => %{"q" => q}}, socket) do
    {:noreply, assign(socket, :list_domain_query, String.trim(q || ""))}
  end

  def handle_event("create_shortlink", %{"shortlink" => params}, socket) do
    allowed_domains = shortlink_available_domain_names(socket.assigns.domains, socket.assigns.remote_domains)

    case Shortlink.create_short_link(params, socket.assigns.current_admin.id, allowed_domains) do
      {:ok, _short_link} ->
        {:noreply,
         socket
         |> put_flash(:info, "Shortlink berhasil dibuat.")
         |> assign_shortlink_list()
         |> assign_shortlink_stats()
         |> assign(:shortlink_form, to_form(Shortlink.new_short_link_form_defaults(allowed_domains), as: :shortlink))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}
    end
  end

  def handle_event("search_shortlink_list", %{"shortlink_search" => %{"q" => q}}, socket) do
    query = String.trim(q || "")
    {:noreply, socket |> assign(:shortlink_query, query) |> assign_shortlink_list()}
  end

  def handle_event("set_shortlink_redirect_type", %{"id" => id, "type" => type}, socket) do
    with {shortlink_id, _} <- Integer.parse(to_string(id)),
         {redirect_type, _} <- Integer.parse(to_string(type)),
         {:ok, _shortlink} <- Shortlink.update_redirect_type(shortlink_id, redirect_type) do
      {:noreply,
       socket
       |> put_flash(:info, "Redirect type diperbarui.")
       |> assign_shortlink_list()
       |> assign_shortlink_stats()}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}
    end
  end

  def handle_event("delete_short_link", %{"id" => id}, socket) do
    with {shortlink_id, _} <- Integer.parse(to_string(id)),
         {:ok, deleted_link} <- Shortlink.delete_short_link(shortlink_id) do
      {:noreply,
       socket
       |> put_flash(:info, "Shortlink '#{deleted_link.slug}' berhasil dihapus.")
       |> assign_shortlink_list()
       |> assign_shortlink_stats()}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Shortlink tidak ditemukan.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Gagal menghapus shortlink. Coba lagi.")}
    end
  end

  def handle_event("search_shortlink_rotator", %{"shortlink_rotator_search" => %{"q" => q}}, socket) do
    query = String.trim(q || "")
    {:noreply, socket |> assign(:shortlink_rotator_query, query) |> assign_shortlink_rotator_data()}
  end

  def handle_event("edit_shortlink_rotator", %{"id" => id}, socket) do
    with {short_link_id, _} <- Integer.parse(to_string(id)),
         link when is_map(link) <- Enum.find(socket.assigns.shortlink_rotator_links, &(&1.id == short_link_id)) do
      {:noreply,
       socket
       |> assign(:rotator_form, to_form(rotator_form_from_link(link), as: :rotator))
       |> assign(:rotator_modal_open, true)
       |> assign(:rotator_modal_link, link)
       |> assign(:rotator_primary_form, to_form(rotator_primary_form_from_link(link), as: :rotator_primary))}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}
    end
  end

  def handle_event("close_rotator_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:rotator_modal_open, false)
     |> assign(:rotator_modal_link, nil)
     |> assign(:rotator_primary_form, to_form(rotator_primary_form_defaults(), as: :rotator_primary))}
  end

  def handle_event("save_rotator_primary_domain", %{"rotator_primary" => params}, socket) do
    with {short_link_id, _} <- params |> Map.get("short_link_id", "") |> to_string() |> Integer.parse() do
      allowed_domains =
        shortlink_available_domain_names(socket.assigns.domains, socket.assigns.remote_domains)

      destination_domain =
        params
        |> Map.get("destination_domain", "")
        |> to_string()
        |> String.trim()

      case Shortlink.update_primary_destination(short_link_id, destination_domain, allowed_domains) do
        {:ok, _short_link} ->
          refreshed_socket = assign_shortlink_rotator_data(socket)

          refreshed_modal_link =
            Enum.find(refreshed_socket.assigns.shortlink_rotator_links, &(&1.id == short_link_id))

          {:noreply,
           refreshed_socket
           |> assign(:rotator_modal_link, refreshed_modal_link)
           |> assign(:rotator_form, to_form(rotator_form_from_link(refreshed_modal_link), as: :rotator))
           |> assign(
             :rotator_primary_form,
             to_form(rotator_primary_form_defaults(short_link_id, destination_domain), as: :rotator_primary)
           )
           |> put_flash(:info, "Primary domain shortlink berhasil diperbarui.")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}
      end
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}
    end
  end

  def handle_event("save_shortlink_rotator", %{"rotator" => params}, socket) do
    case Shortlink.save_rotator_config(params) do
      {:ok, :saved} ->
        short_link_id =
          case params |> Map.get("short_link_id", "") |> to_string() |> Integer.parse() do
            {value, _} -> value
            _ -> nil
          end

        refreshed_socket =
          socket
          |> assign_shortlink_rotator_data()
          |> put_flash(:info, "Rotator shortlink berhasil disimpan.")

        refreshed_modal_link =
          if is_integer(short_link_id) do
            Enum.find(refreshed_socket.assigns.shortlink_rotator_links, &(&1.id == short_link_id))
          else
            nil
          end

        {:noreply,
         if refreshed_socket.assigns.rotator_modal_open and is_map(refreshed_modal_link) do
           refreshed_socket
           |> assign(:rotator_modal_link, refreshed_modal_link)
           |> assign(:rotator_form, to_form(rotator_form_from_link(refreshed_modal_link), as: :rotator))
         else
           refreshed_socket
           |> assign(:rotator_form, to_form(Shortlink.new_rotator_form_defaults(), as: :rotator))
         end}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}
    end
  end

  def handle_event("delete_remote_domain", %{"id" => id} = params, socket) do
    profile_id_param = Map.get(params, "profile_id")

    with {remote_id, _} <- Integer.parse(id),
         {:ok, _result} <- delete_remote_domain_with_profile(remote_id, profile_id_param) do
      {:noreply,
       socket
       |> put_flash(:info, "Domain remote id #{remote_id} berhasil dihapus.")
       |> assign_domains(Monitor.list_domains())
       |> assign_remote_domains()}
    else
      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}
    end
  end

  def handle_event("live_check_remote_domain", %{"id" => id} = params, socket) do
    profile_id_param = Map.get(params, "profile_id")
    row_key = Map.get(params, "key", id)

    with {remote_id, _} <- Integer.parse(id),
         {:ok, result} <- live_check_remote_domain_with_profile(remote_id, profile_id_param) do
      statuses = Map.put(socket.assigns.remote_statuses, row_key, result.status)

      {:noreply,
       socket
       |> assign(:remote_statuses, statuses)
       |> put_flash(:info, "Live status domain id #{remote_id}: #{result.status}")}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}
    end
  end

  def handle_event("admin_manager_change_password", %{"admin_manager" => params}, socket) do
    current_password = Map.get(params, "current_password", "")
    new_password = Map.get(params, "password", "")
    password_confirmation = Map.get(params, "password_confirmation", "")

    case Accounts.change_admin_password(socket.assigns.current_admin, current_password, new_password, password_confirmation) do
      {:ok, updated_admin} ->
        {:noreply,
         socket
         |> assign(:current_admin, updated_admin)
         |> assign(:admin_manager_change_form, admin_manager_change_form())
         |> put_flash(:info, "Password admin berhasil diperbarui.")}

      {:error, :invalid_current_password} ->
        {:noreply, put_flash(socket, :error, "Current password tidak sesuai.")}

      {:error, :password_required} ->
        {:noreply, put_flash(socket, :error, "New password wajib diisi.")}

      {:error, :password_confirmation_mismatch} ->
        {:noreply, put_flash(socket, :error, "Konfirmasi password baru tidak sama.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Password baru tidak valid. Pastikan memenuhi kebijakan minimum password."
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Gagal memperbarui password admin. Silakan coba lagi.")}
    end
  end

  def handle_event("save_admin_reset_settings", %{"admin_reset" => params}, socket) do
    normalized = %{
      "admin_reset_telegram_bot_token" =>
        params
        |> Map.get("admin_reset_telegram_bot_token", "")
        |> to_string()
        |> String.trim(),
      "admin_reset_telegram_group_chat_id" =>
        params
        |> Map.get("admin_reset_telegram_group_chat_id", "")
        |> to_string()
        |> String.trim()
    }

    Monitor.upsert_settings(normalized)
    updated_settings = Monitor.list_settings()

    {:noreply,
     socket
     |> assign(:settings, updated_settings)
     |> assign(:admin_manager_reset_settings_form, admin_manager_reset_settings_form(updated_settings))
     |> put_flash(:info, "Konfigurasi Telegram reset password berhasil disimpan.")}
  end

  def handle_event("save_settings", %{"settings" => settings}, socket) do
    current_settings = Monitor.list_settings()

    normalized =
      settings
      |> Map.put("sflink_base_url", "https://app.sflink.id")
      |> Map.put_new("telegram_notifications_enabled", "false")
      |> Map.put_new("telegram_group_notifications_enabled", "false")
      |> Map.put_new("telegram_private_notifications_enabled", "false")
      |> Map.update!("telegram_notifications_enabled", fn
        "true" -> "true"
        _ -> "false"
      end)
      |> Map.update!("telegram_group_notifications_enabled", fn
        "true" -> "true"
        _ -> "false"
      end)
      |> Map.update!("telegram_private_notifications_enabled", fn
        "true" -> "true"
        _ -> "false"
      end)
      |> Map.update("telegram_bot_token", "", &preserve_existing_setting(&1, current_settings["telegram_bot_token"]))
      |> Map.update(
        "telegram_group_chat_id",
        "",
        &preserve_existing_setting(&1, current_settings["telegram_group_chat_id"])
      )
      |> Map.update(
        "telegram_private_chat_id",
        "",
        &preserve_existing_setting(&1, current_settings["telegram_private_chat_id"])
      )

    Monitor.upsert_settings(normalized)

    updated_settings = Monitor.list_settings()
    info_message =
      if socket.assigns.current_page == :telegram,
        do: "Pengaturan Telegram berhasil disimpan.",
        else: "API Token berhasil tersimpan."

    socket =
      socket
      |> put_flash(:info, info_message)
      |> assign(:settings, updated_settings)
      |> assign(:settings_form, to_form(updated_settings, as: :settings))

    socket =
      if socket.assigns.current_page == :profile do
        socket
        |> assign_sflink_profile()
        |> assign(:sflink_profiles, Monitor.list_sflink_profiles())
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("save_telegram_settings", %{"settings" => settings}, socket) do
    current = Monitor.list_settings()

    normalized = %{
      "telegram_bot_token" => preserve_existing_setting(Map.get(settings, "telegram_bot_token", ""), current["telegram_bot_token"]),
      "telegram_group_chat_id" => preserve_existing_setting(Map.get(settings, "telegram_group_chat_id", ""), current["telegram_group_chat_id"]),
      "telegram_private_chat_id" => preserve_existing_setting(Map.get(settings, "telegram_private_chat_id", ""), current["telegram_private_chat_id"]),
      "telegram_notifications_enabled" =>
        if(Map.get(settings, "telegram_notifications_enabled", "false") == "true", do: "true", else: "false"),
      "telegram_group_notifications_enabled" =>
        if(Map.get(settings, "telegram_group_notifications_enabled", "false") == "true", do: "true", else: "false"),
      "telegram_private_notifications_enabled" =>
        if(Map.get(settings, "telegram_private_notifications_enabled", "false") == "true", do: "true", else: "false")
    }

    :ok = Monitor.upsert_settings(normalized)
    :timer.sleep(100)
    updated = Monitor.list_settings()

    persisted? =
      updated["telegram_bot_token"] == normalized["telegram_bot_token"] and
        updated["telegram_group_chat_id"] == normalized["telegram_group_chat_id"] and
        updated["telegram_private_chat_id"] == normalized["telegram_private_chat_id"]

    flash_type = if persisted?, do: :info, else: :error

    flash_message =
      if persisted? do
        "Konfigurasi Telegram berhasil disimpan dan terverifikasi."
      else
        "Konfigurasi Telegram gagal diverifikasi setelah simpan. Coba lagi."
      end

    {:noreply,
     socket
     |> put_flash(flash_type, flash_message)
     |> assign(:settings, updated)
     |> assign(:settings_form, to_form(updated, as: :settings))}
  end

  def handle_event("clear_sflink_token", _params, socket) do
    case Monitor.clear_active_sflink_token() do
      {:ok, _} ->
        settings = Monitor.list_settings()

        {:noreply,
         socket
         |> put_flash(:info, "SFLINK API token berhasil dihapus.")
         |> assign(:settings, settings)
         |> assign(:settings_form, to_form(settings, as: :settings))
         |> assign(:sflink_profiles, Monitor.list_sflink_profiles())
         |> assign(:sflink_profile, nil)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}
    end
  end

  def handle_event("add_sflink_profile", %{"sflink_profile" => params}, socket) do
    case Monitor.create_sflink_profile(params) do
      {:ok, _profile} ->
        settings = Monitor.list_settings()

        {:noreply,
         socket
         |> put_flash(:info, "Profile SFLINK berhasil ditambahkan.")
         |> assign(:settings, settings)
         |> assign(:settings_form, to_form(settings, as: :settings))
         |> assign(:sflink_profiles, Monitor.list_sflink_profiles())
         |> assign_sflink_profile()
         |> assign(:sflink_profile_form, to_form(%{"name" => "", "api_token" => ""}, as: :sflink_profile))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")
         |> assign(:sflink_profile_form, to_form(changeset, as: :sflink_profile))}

      {:error, :token_limit} ->
        {:noreply,
         socket
         |> put_flash(:error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}
    end
  end

  def handle_event("activate_sflink_profile", %{"id" => id}, socket) do
    with {profile_id, _} <- Integer.parse(id),
         {:ok, _} <- Monitor.activate_sflink_profile(profile_id) do
      settings = Monitor.list_settings()

      {:noreply,
       socket
       |> put_flash(:info, "Profile SFLINK berhasil diaktifkan.")
       |> assign(:settings, settings)
       |> assign(:settings_form, to_form(settings, as: :settings))
       |> assign(:sflink_profiles, Monitor.list_sflink_profiles())
       |> assign_sflink_profile()}
    else
      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}
    end
  end

  def handle_event("delete_sflink_profile", %{"id" => id}, socket) do
    with {profile_id, _} <- Integer.parse(id),
         {:ok, _} <- Monitor.delete_sflink_profile(profile_id) do
      settings = Monitor.list_settings()

      {:noreply,
       socket
       |> put_flash(:info, "Profile SFLINK berhasil dihapus.")
       |> assign(:settings, settings)
       |> assign(:settings_form, to_form(settings, as: :settings))
       |> assign(:sflink_profiles, Monitor.list_sflink_profiles())
       |> assign_sflink_profile()}
    else
      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}
    end
  end

  def handle_event("run_checker_now", _params, socket) do
    case ElixirNawala.Workers.CheckerCycleWorker.enqueue() do
      {:ok, _job} ->
        {:noreply, put_flash(socket, :info, "Checker cycle berhasil di-queue.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")}
    end
  end

  def handle_event("test_group", _params, socket) do
    msg = socket.assigns.test_message
    reply = if Notifier.send_test_message(:group, msg) == :ok, do: {:info, "Test message ke group terkirim."}, else: {:error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi."}
    {:noreply, put_flash(socket, elem(reply, 0), elem(reply, 1))}
  end

  def handle_event("test_private", _params, socket) do
    msg = socket.assigns.test_message
    reply = if Notifier.send_test_message(:private, msg) == :ok, do: {:info, "Test message ke private chat terkirim."}, else: {:error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi."}
    {:noreply, put_flash(socket, elem(reply, 0), elem(reply, 1))}
  end

  def handle_event("toggle_sidebar_collapse", _params, socket) do
    {:noreply, assign(socket, :sidebar_collapsed, !socket.assigns.sidebar_collapsed)}
  end

  def handle_event("toggle_sidebar_mobile", _params, socket) do
    {:noreply, assign(socket, :sidebar_open, !socket.assigns.sidebar_open)}
  end

  def handle_event("close_sidebar_mobile", _params, socket) do
    {:noreply, assign(socket, :sidebar_open, false)}
  end

  def handle_event("toggle_domain_menu", _params, socket) do
    {:noreply, assign(socket, :domain_menu_open, !socket.assigns.domain_menu_open)}
  end

  def handle_event("toggle_shortlink_menu", _params, socket) do
    {:noreply, assign(socket, :shortlink_menu_open, !socket.assigns.shortlink_menu_open)}
  end

  def handle_event("toggle_admin_menu", _params, socket) do
    {:noreply, assign(socket, :admin_menu_open, !socket.assigns.admin_menu_open)}
  end

  def handle_event("set_home_time_range", %{"range" => range}, socket) do
    normalized = normalize_home_time_range(range)
    {:noreply, assign_home_analytics(socket, normalized)}
  end

  def handle_event("refresh_home_analytics", _params, socket) do
    {:noreply,
     socket
     |> assign_remote_domains(false)
     |> live_check_all_remote_domains()
     |> assign(:home_next_refresh_seconds, 30)
     |> assign_home_analytics(socket.assigns.home_time_range || "7d")
     |> put_flash(:info, "Home analytics diperbarui dari live status terbaru.")}
  end

  @impl true
  def handle_info({:domain_updated, _domain}, socket) do
    socket = assign_domains(socket, Monitor.list_domains())

    socket =
      if socket.assigns.current_page == :home do
        assign_home_analytics(socket, socket.assigns.home_time_range || "7d")
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:checker_cycle_finished, summary}, socket) do
    socket = assign(socket, :last_cycle_info, summary)

    socket =
      if socket.assigns.current_page == :home do
        assign_home_analytics(socket, socket.assigns.home_time_range || "7d")
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:status_tick, socket) do
    now = DateTime.utc_now()
    seconds = max((socket.assigns.next_refresh_seconds || 1) - 1, 0)
    home_seconds = max((socket.assigns.home_next_refresh_seconds || 1) - 1, 0)

    socket =
      socket
      |> assign(:status_clock, now)
      |> assign(:next_refresh_seconds, seconds)
      |> assign(:home_next_refresh_seconds, home_seconds)

    socket =
      if socket.assigns.current_page == :status_domain and seconds == 0 do
        socket
        |> assign_remote_domains(false)
        |> live_check_all_remote_domains()
        |> assign_next_refresh_seconds()
      else
        socket
      end

    socket =
      if socket.assigns.current_page == :home and home_seconds == 0 do
        socket
        |> assign_remote_domains(false)
        |> live_check_all_remote_domains()
        |> assign_home_analytics(socket.assigns.home_time_range || "7d")
        |> assign(:home_next_refresh_seconds, 30)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class={["admin-shell", @sidebar_collapsed && "sidebar-collapsed", @sidebar_open && "sidebar-open"]}>
      <header class="admin-topbar">
        <div class="topbar-left">
          <button type="button" class="sidebar-toggle-btn" phx-click="toggle_sidebar_mobile" aria-label="Toggle sidebar">
            <.nav_icon name="domain" />
          </button>
          <span class="phoenix-mark">
            <.nav_icon name="phoenix" />
          </span>
          <span class="phoenix-word">Elixir Nawala</span>
        </div>
        <div class="topbar-right">
          <button type="button" class="icon-btn icon-btn-notify" aria-label="Notifications">
            <.nav_icon name="bell" />
          </button>
          <.link href="/admin/logout" method="delete" class="ghost-btn">Logout</.link>
        </div>
      </header>

      <aside class="admin-sidebar">
        <nav class="sidebar-nav">
          <.link class={menu_class(@current_page == :home)} href="/admin/home">
            <span class="menu-arrow"></span>
            <span class="menu-icon">
              <.nav_icon name="home" />
            </span>
            <span class="menu-label">Home</span>
          </.link>

          <p class="menu-group">APPS</p>

          <div class={["menu-expand", @domain_menu_open && "open"]} data-pop-title="Domain">
            <button type="button" class={menu_class(@current_page in [:add_domain, :list_domain, :status_domain])} phx-click="toggle_domain_menu">
              <span class="menu-arrow"></span>
              <span class="menu-icon">
                <.nav_icon name="domain" />
              </span>
              <span class="menu-label">Domain</span>
            </button>
            <div class="submenu-pop">
              <p class="submenu-pop-title">Domain</p>
              <.link class={submenu_class(@current_page == :add_domain)} href="/admin/domain/add">Add Domain</.link>
              <.link class={submenu_class(@current_page == :status_domain)} href="/admin/domain/status">Domain Status</.link>
              <.link class={submenu_class(@current_page == :list_domain)} href="/admin/domain/list">List Domain</.link>
            </div>
          </div>

          <div class={["menu-expand", @shortlink_menu_open && "open"]} data-pop-title="Shortlink">
            <button type="button" class={menu_class(@current_page in [:shortlink_create, :shortlink_list, :shortlink_stats, :shortlink_rotator])} phx-click="toggle_shortlink_menu">
              <span class="menu-arrow"></span>
              <span class="menu-icon">
                <.nav_icon name="shortlink" />
              </span>
              <span class="menu-label">Shortlink</span>
            </button>
            <div class="submenu-pop">
              <p class="submenu-pop-title">Shortlink</p>
              <.link class={submenu_class(@current_page == :shortlink_create)} href="/admin/shortlink/create">Create Shortlink</.link>
              <.link class={submenu_class(@current_page == :shortlink_list)} href="/admin/shortlink/list">List Shortlink</.link>
              <.link class={submenu_class(@current_page == :shortlink_stats)} href="/admin/shortlink/stats">Stats Shortlink</.link>
              <.link class={submenu_class(@current_page == :shortlink_rotator)} href="/admin/shortlink/rotator">Rotator</.link>
            </div>
          </div>

          <.link class={menu_class(@current_page == :telegram)} href="/admin/telegram">
            <span class="menu-arrow blank"></span>
            <span class="menu-icon">
              <.nav_icon name="telegram" />
            </span>
            <span class="menu-label">Telegram</span>
          </.link>

          <div class={["menu-expand", @admin_menu_open && "open"]} data-pop-title="Admin">
            <button type="button" class={menu_class(@current_page in [:profile, :admin_manager])} phx-click="toggle_admin_menu">
              <span class="menu-arrow"></span>
              <span class="menu-icon">
                <.nav_icon name="admin" />
              </span>
              <span class="menu-label">Admin</span>
            </button>
            <div class="submenu-pop">
              <p class="submenu-pop-title">Admin</p>
              <.link class={submenu_class(@current_page == :profile)} href="/admin/profile">Profile</.link>
              <.link class={submenu_class(@current_page == :admin_manager)} href="/admin/manager">Admin Manager</.link>
            </div>
          </div>
        </nav>

        <button type="button" class="sidebar-footer" phx-click="toggle_sidebar_collapse">
          <span class="menu-icon">
            <.nav_icon name={if @sidebar_collapsed, do: "expand", else: "collapse"} />
          </span>
          <span>Collapsed View</span>
        </button>
      </aside>

      <button :if={@sidebar_open} type="button" class="sidebar-backdrop" phx-click="close_sidebar_mobile" aria-label="Close sidebar"></button>

      <div class="admin-main">
        <div class="admin-content">
          <%= if @current_page == :home do %>
            <section id="overview" class="card-dark" style="padding: 1.4rem;">
              <div style="display: flex; justify-content: space-between; align-items: center; gap: 1rem; flex-wrap: wrap;">
                <div>
                  <h1 class="admin-title" style="margin: 0;">Elixir Nawala Analytics</h1>
                  <p class="admin-subtitle" style="margin-top: 0.3rem;">Ringkasan click shortlink dan domain health berbasis live check status.</p>
                </div>
                <div style="display: inline-flex; gap: 0.45rem; flex-wrap: wrap; align-items: center;">
                  <button
                    :for={{key, label} <- @home_analytics.range_options}
                    type="button"
                    phx-click="set_home_time_range"
                    phx-value-range={key}
                    class={["ghost-btn", @home_time_range == key && "active"]}
                    style={if @home_time_range == key, do: "background: #1f2f55; color: #f7fbff; border-color: #5f88ff;", else: ""}
                  >
                    {label}
                  </button>
                </div>
              </div>
              <p class="admin-subtitle" style="margin-top: 0.45rem;">
                Source: {@home_analytics.totals.source} | Auto refresh live: {countdown_label_seconds(@home_next_refresh_seconds || 0)}
              </p>

              <div class="admin-grid profile-grid" style="margin-top: 1rem;">
                <article class="card-dark">
                  <h3 style="margin: 0;">Total Click</h3>
                  <p class="kpi-value" style="margin-top: 0.35rem;">{format_number(@home_analytics.totals.clicks)}</p>
                </article>
                <article class="card-dark">
                  <h3 style="margin: 0;">Total Domain</h3>
                  <p class="kpi-value" style="margin-top: 0.35rem;">{format_number(@home_analytics.totals.domains)}</p>
                </article>
                <article class="card-dark">
                  <h3 style="margin: 0;">Domain Trusted</h3>
                  <p class="kpi-value" style="margin-top: 0.35rem; color: #5ecf95;">{format_number(@home_analytics.totals.trusted)}</p>
                </article>
                <article class="card-dark">
                  <h3 style="margin: 0;">Domain Blocked</h3>
                  <p class="kpi-value" style="margin-top: 0.35rem; color: #ff7b7b;">{format_number(@home_analytics.totals.blocked)}</p>
                </article>
              </div>

              <article class="card-dark" style="margin-top: 1rem;">
                <div style="display: flex; justify-content: space-between; align-items: center; gap: 0.8rem; flex-wrap: wrap;">
                  <h3 style="margin: 0;">Trend {Map.get(@home_analytics.range_options, @home_time_range, "7 Hari")}</h3>
                  <div style="display: inline-flex; gap: 0.9rem; flex-wrap: wrap; font-size: 0.85rem;">
                    <span><span style="display:inline-block;width:10px;height:10px;border-radius:99px;background:#5f88ff;margin-right:0.35rem;"></span>Total Click</span>
                    <span><span style="display:inline-block;width:10px;height:10px;border-radius:99px;background:#5ecf95;margin-right:0.35rem;"></span>Trusted</span>
                    <span><span style="display:inline-block;width:10px;height:10px;border-radius:99px;background:#ff7b7b;margin-right:0.35rem;"></span>Blocked</span>
                    <span><span style="display:inline-block;width:10px;height:10px;border-radius:99px;background:#94a3b8;margin-right:0.35rem;"></span>Unknown</span>
                  </div>
                </div>

                <div style="margin-top: 0.8rem; overflow-x: auto;">
                  <svg viewBox={"0 0 #{@home_analytics.chart.width} #{@home_analytics.chart.height}"} width="100%" height="330" role="img" aria-label="Analytics chart">
                    <rect x="0" y="0" width={@home_analytics.chart.width} height={@home_analytics.chart.height} fill="#0f172b" rx="14" />
                    <line
                      :for={tick <- @home_analytics.chart.y_ticks}
                      x1={@home_analytics.chart.padding_left}
                      y1={tick.y}
                      x2={@home_analytics.chart.width - @home_analytics.chart.padding_right}
                      y2={tick.y}
                      stroke="#1d2a4b"
                      stroke-width="1"
                    />
                    <text
                      :for={tick <- @home_analytics.chart.y_ticks}
                      x={@home_analytics.chart.padding_left - 10}
                      y={tick.y + 4}
                      fill="#88a1cf"
                      text-anchor="end"
                      font-size="11"
                    >
                      {tick.label}
                    </text>

                    <path d={@home_analytics.chart.series.clicks.area_path} fill="rgba(95,136,255,0.14)" stroke="none" />
                    <path d={@home_analytics.chart.series.trusted.area_path} fill="rgba(94,207,149,0.12)" stroke="none" />
                    <path d={@home_analytics.chart.series.blocked.area_path} fill="rgba(255,123,123,0.10)" stroke="none" />

                    <path d={@home_analytics.chart.series.clicks.path} fill="none" stroke="#5f88ff" stroke-width="2.8" stroke-linecap="round" />
                    <path d={@home_analytics.chart.series.trusted.path} fill="none" stroke="#5ecf95" stroke-width="2.8" stroke-linecap="round" />
                    <path d={@home_analytics.chart.series.blocked.path} fill="none" stroke="#ff7b7b" stroke-width="2.8" stroke-linecap="round" />

                    <circle :for={point <- @home_analytics.chart.series.clicks.markers} cx={point.x} cy={point.y} r="2.3" fill="#5f88ff" />
                    <circle :for={point <- @home_analytics.chart.series.trusted.markers} cx={point.x} cy={point.y} r="2.3" fill="#5ecf95" />
                    <circle :for={point <- @home_analytics.chart.series.blocked.markers} cx={point.x} cy={point.y} r="2.3" fill="#ff7b7b" />

                    <line
                      x1={@home_analytics.chart.padding_left}
                      y1={@home_analytics.chart.height - @home_analytics.chart.padding_bottom}
                      x2={@home_analytics.chart.width - @home_analytics.chart.padding_right}
                      y2={@home_analytics.chart.height - @home_analytics.chart.padding_bottom}
                      stroke="#31436f"
                      stroke-width="1.2"
                    />
                    <text
                      :for={label <- @home_analytics.chart.x_labels}
                      x={label.x}
                      y={@home_analytics.chart.height - 12}
                      fill="#9cb2de"
                      text-anchor="middle"
                      font-size="11"
                    >
                      {label.label}
                    </text>
                  </svg>
                </div>
              </article>
            </section>
          <% end %>

          <%= if @current_page == :add_domain do %>
            <section id="domain-add" class="card-dark add-domain-card">
              <div class="add-domain-grid">
                <article class="add-domain-hero">
                  <h2>Tambah Domain</h2>
                  <p class="admin-subtitle">
                    Daftarkan domain untuk monitoring TrustPositif via SFLINK dan sinkronisasi status secara realtime.
                  </p>

                  <div class="add-domain-points">
                    <div class="add-domain-point">
                      <span class="point-icon"><.status_icon name="shield" /></span>
                      <div>
                        <strong>Keamanan Aktif</strong>
                        <p>Status domain dipantau untuk deteksi BLOCKED/TRUSTED.</p>
                      </div>
                    </div>
                    <div class="add-domain-point">
                      <span class="point-icon"><.status_icon name="link" /></span>
                      <div>
                        <strong>Sinkron SFLINK</strong>
                        <p>Domain baru langsung dikirim ke endpoint API SFLINK.</p>
                      </div>
                    </div>
                    <div class="add-domain-point">
                      <span class="point-icon"><.status_icon name="clock" /></span>
                      <div>
                        <strong>Auto Monitoring</strong>
                        <p>Data domain otomatis tersedia di List Domain dan Domain Status.</p>
                      </div>
                    </div>
                  </div>
                </article>

                <article class="add-domain-form-card">
                  <h3>Form Tambah Domain</h3>
                  <.form for={@domain_form} action="/admin/domains" method="post" phx-submit="create_domain">
                    <label for="add-domain-profile">User Profile</label>
                    <select
                      id="add-domain-profile"
                      name="domain[profile_id]"
                      class="add-domain-profile-select"
                      required
                      disabled={@add_domain_profiles == []}
                    >
                      <option value="">Pilih user profile</option>
                      <option
                        :for={profile <- @add_domain_profiles}
                        value={profile.id}
                        selected={to_string(@domain_form[:profile_id].value) == to_string(profile.id)}
                      >
                        {profile_option_label(profile)}
                      </option>
                    </select>
                    <p :if={add_domain_quota_label(@add_domain_profiles, @domain_form[:profile_id].value)} class="add-domain-profile-badge">
                      {add_domain_quota_label(@add_domain_profiles, @domain_form[:profile_id].value)}
                    </p>

                    <label for="add-domain-input">Nama Domain</label>
                    <input
                      id="add-domain-input"
                      type="text"
                      name="domain[name]"
                      value={@domain_form[:name].value}
                      placeholder="contoh: example.com"
                      autocomplete="off"
                      disabled={@add_domain_profiles == []}
                      required
                    />
                    <p class="form-hint">Gunakan format domain tanpa http/https untuk validasi yang lebih akurat.</p>
                    <p :if={@add_domain_profiles == []} class="form-hint">
                      Tidak ada user profile dengan kuota domain tersedia.
                    </p>
                    <div class="actions">
                      <button type="submit" disabled={@add_domain_profiles == []}>
                        <.status_icon name="check" /> Tambahkan Domain
                      </button>
                    </div>
                  </.form>
                </article>
              </div>

            </section>
          <% end %>

          <%= if @current_page == :status_domain do %>
            <section id="domain-status" class="domain-status-card">
              <div class="domain-status-head">
                <h2>
                  <span class="head-icon"><.status_icon name="shield" /></span>
                  Domain Status
                </h2>
                <button type="button" class="refresh-btn" phx-click="refresh_remote_domains">Refresh</button>
              </div>

              <div class="system-banner">
                <span class="system-dot"></span>
                <div>
                  <p class="system-line"><strong>System Status:</strong> Active</p>
                  <p class="system-sub">
                    Last updated: {jakarta_time(@status_clock)} | Next refresh: {countdown_label_seconds(@next_refresh_seconds)}
                  </p>
                </div>
              </div>

              <div class="status-grid-head">
                <span><.status_icon name="globe" /> DOMAIN</span>
                <span><.status_icon name="pulse" /> MONITOR STATUS</span>
                <span>LAST CHECK</span>
                <span><.status_icon name="gear" /> INTERVAL</span>
                <span><.status_icon name="shield" /> CHECK STATUS</span>
                <span><.status_icon name="clock" /> NEXT CHECK</span>
                <span><.status_icon name="link" /> LIVE CHECK</span>
              </div>

              <div class="status-grid-row" :for={rd <- @remote_domains}>
                <div class="domain-col">
                  <div class="domain-avatar"><.status_icon name="globe" /></div>
                  <div>
                    <p class="domain-name">{rd.domain}</p>
                    <p class="domain-meta">
                      Added {format_added_date(rd.created_at)}
                    </p>
                  </div>
                </div>

                <div>
                  <span class={"badge " <> monitor_status_class(rd.status)}>
                    <.status_icon name="check" /> {monitor_status_label(rd.status)}
                  </span>
                </div>

                <div>
                  <p class="mono-line">{format_api_datetime(rd.last_checked, "%d %b %H:%M")}</p>
                  <p class="domain-meta">{relative_last_check(rd.last_checked, @status_clock)}</p>
                </div>

                <div>
                  <span class="badge badge-blue"><.status_icon name="clock" /> {interval_label(rd.check_interval_minutes, @settings["checker_interval_seconds"])}</span>
                </div>

                <div>
                  <span class={"badge " <> check_status_class(rd, @remote_statuses)}>
                    <.status_icon name="shield" /> {check_status_text(rd, @remote_statuses)}
                  </span>
                </div>

                <div>
                  <p class="mono-line">{next_check_time_from_api(rd, @status_clock)}</p>
                  <p class="domain-meta">{countdown_label(rd, @status_clock)}</p>
                </div>

                <div>
                  <button
                    class="inline-action"
                    phx-click="live_check_remote_domain"
                    phx-value-id={rd.id}
                    phx-value-profile_id={rd.source_profile_id}
                    phx-value-key={remote_domain_key(rd)}
                  >
                    <.status_icon name="link" /> Live Check
                  </button>
                </div>
              </div>

              <div class="status-note">
                <strong>Auto Check Information</strong>
                <p>
                  Domains are automatically checked based on their individual interval settings.
                  TrustPositif status is checked on page load and displayed next to domain name.
                </p>
              </div>
            </section>
          <% end %>

          <%= if @current_page == :list_domain do %>
            <section id="domain-list" class="card-dark">
              <div class="list-domain-head">
                <h2 class="list-domain-title">List Domain</h2>
                <.form for={to_form(%{"q" => @list_domain_query}, as: :domain_search)} phx-change="search_domain_list" class="list-domain-search-form">
                  <input
                    type="text"
                    name="domain_search[q]"
                    value={@list_domain_query}
                    placeholder="Cari domain..."
                    class="list-domain-search"
                    phx-debounce="250"
                    autocomplete="off"
                  />
                </.form>
              </div>
              <div class="table-wrap">
                <table class="domain-list-table">
                  <thead>
                    <tr>
                      <th>Remote ID</th>
                      <th>Profile</th>
                      <th>Domain</th>
                      <th>Status</th>
                      <th class="action-col">Action</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={rd <- filtered_remote_domains(@remote_domains, @list_domain_query)}>
                      <td>{rd.id}</td>
                      <td>{rd.source_profile_name || "Default"}</td>
                      <td>{rd.domain}</td>
                      <td>
                        <span class={"badge " <> check_status_class(rd, @remote_statuses)}>
                          <.status_icon name="shield" /> {check_status_text(rd, @remote_statuses)}
                        </span>
                      </td>
                      <td class="action-col">
                        <button phx-click="delete_remote_domain" phx-value-id={rd.id} phx-value-profile_id={rd.source_profile_id}>Delete</button>
                      </td>
                    </tr>
                    <tr :if={filtered_remote_domains(@remote_domains, @list_domain_query) == []}>
                      <td colspan="5">Domain tidak ditemukan.</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </section>
          <% end %>

          <%= if @current_page == :shortlink_create do %>
            <section id="shortlink-create" class="card-dark shortlink-shell">
              <div class="shortlink-head-row">
                <div class="shortlink-head">
                  <h2>Create Shortlink</h2>
                  <p>Kelola tautan singkat berbasis slug dengan struktur yang konsisten dan mudah dipantau.</p>
                </div>
                <div class="shortlink-head-meta">
                  <span class="shortlink-meta-pill">Slug Based</span>
                  <span class="shortlink-meta-pill">Click Tracking</span>
                </div>
              </div>

              <div class="shortlink-pattern">
                <span class="pattern-label">Format URL</span>
                <code>{shortlink_pattern_url()}</code>
              </div>

              <div class="shortlink-create-grid">
                <article class="card-dark shortlink-form-card">
                  <h3>Generate Link</h3>
                  <p class="shortlink-card-subtitle">Isi destination URL, tentukan slug, lalu pilih tipe redirect.</p>
                  <.form for={@shortlink_form} phx-submit="create_shortlink" class="shortlink-form-grid">
                    <div class="shortlink-field">
                      <label>Destination URL</label>
                      <div class="shortlink-select-wrap">
                        <span class="shortlink-select-prefix">https://</span>
                        <select class="shortlink-domain-select" name="shortlink[destination_url]" required>
                          <option :if={shortlink_domain_options(@domains, @remote_domains) == []} value="">Tidak ada domain tersedia</option>
                          <option :if={shortlink_domain_options(@domains, @remote_domains) != []} value="" disabled={true}>Pilih domain tujuan</option>
                          <optgroup :if={active_shortlink_domains(shortlink_domain_options(@domains, @remote_domains)) != []} label="Active Domains">
                            <option
                              :for={domain <- active_shortlink_domains(shortlink_domain_options(@domains, @remote_domains))}
                              value={"https://#{domain}"}
                              selected={to_string(@shortlink_form[:destination_url].value) == "https://#{domain}"}
                            >
                              {shortlink_domain_option_label(domain)}
                            </option>
                          </optgroup>
                          <optgroup :if={inactive_shortlink_domains(shortlink_domain_options(@domains, @remote_domains)) != []} label="Inactive Domains">
                            <option
                              :for={domain <- inactive_shortlink_domains(shortlink_domain_options(@domains, @remote_domains))}
                              value={"https://#{domain}"}
                              selected={to_string(@shortlink_form[:destination_url].value) == "https://#{domain}"}
                            >
                              {shortlink_domain_option_label(domain)}
                            </option>
                          </optgroup>
                        </select>
                      </div>
                      <p class="shortlink-help">Hanya domain dari List Domain yang bisa dipilih.</p>
                    </div>

                    <div class="shortlink-field">
                      <label>Custom Slug (opsional)</label>
                      <input
                        type="text"
                        name="shortlink[slug]"
                        value={@shortlink_form[:slug].value}
                        placeholder="promo-seo-2026"
                        autocomplete="off"
                      />
                      <p class="shortlink-help">Kosongkan untuk generate slug random otomatis.</p>
                    </div>

                    <div class="shortlink-field">
                      <label>Redirect Type</label>
                      <select name="shortlink[redirect_type]">
                        <option value="302" selected={to_string(@shortlink_form[:redirect_type].value) == "302"}>302 (Temporary)</option>
                        <option value="301" selected={to_string(@shortlink_form[:redirect_type].value) == "301"}>301 (Permanent)</option>
                      </select>
                    </div>

                    <div class="actions">
                      <button type="submit" class="shortlink-submit-btn" disabled={shortlink_domain_options(@domains, @remote_domains) == []}>Generate Shortlink</button>
                    </div>
                  </.form>
                </article>

                <article class="card-dark shortlink-guide-card">
                  <h3>Panduan Cepat</h3>
                  <p class="shortlink-card-subtitle">Praktik yang disarankan supaya shortlink mudah dikelola tim.</p>
                  <div class="shortlink-guide-list">
                    <div class="shortlink-guide-item">
                      <span class="guide-step">1</span>
                      <div>
                        <strong>Gunakan URL final</strong>
                        <p>Hindari URL dengan banyak redirect berantai agar klik lebih cepat.</p>
                      </div>
                    </div>
                    <div class="shortlink-guide-item">
                      <span class="guide-step">2</span>
                      <div>
                        <strong>Pakai slug deskriptif</strong>
                        <p>Gunakan pola yang mudah diingat untuk campaign jangka panjang.</p>
                      </div>
                    </div>
                    <div class="shortlink-guide-item">
                      <span class="guide-step">3</span>
                      <div>
                        <strong>Pilih redirect sesuai tujuan</strong>
                        <p>302 untuk campaign aktif, 301 untuk URL permanen atau evergreen.</p>
                      </div>
                    </div>
                  </div>

                  <div class="shortlink-preview-box">
                    <p class="preview-title">Preview URL</p>
                    <code>{shortlink_pattern_url()}</code>
                  </div>
                </article>
              </div>
            </section>
          <% end %>

          <%= if @current_page == :shortlink_list do %>
            <section id="shortlink-list" class="card-dark shortlink-shell">
              <div class="shortlink-list-head">
                <div>
                  <h2 class="list-domain-title">List Shortlink</h2>
                  <p class="shortlink-list-subtitle">Kelola seluruh shortlink, redirect type, dan performa klik dari satu tabel.</p>
                </div>
                <div class="shortlink-list-metrics">
                  <span class="shortlink-metric-chip">Total: {length(@shortlink_list)}</span>
                  <span class="shortlink-metric-chip">Clicks: {Enum.sum(Enum.map(@shortlink_list, &(&1.click_count || 0)))}</span>
                </div>
              </div>

              <div class="list-domain-head shortlink-list-toolbar">
                <.form for={to_form(%{"q" => @shortlink_query}, as: :shortlink_search)} phx-change="search_shortlink_list" class="list-domain-search-form shortlink-list-search-form">
                  <input
                    type="text"
                    name="shortlink_search[q]"
                    value={@shortlink_query}
                    placeholder="Cari slug atau destination..."
                    class="list-domain-search"
                    phx-debounce="250"
                    autocomplete="off"
                  />
                </.form>
              </div>

              <div class="table-wrap">
                <table class="domain-list-table shortlink-table shortlink-list-table">
                  <thead>
                    <tr>
                      <th>Slug</th>
                      <th>Short URL</th>
                      <th>Destination</th>
                      <th>Redirect</th>
                      <th>Clicks</th>
                      <th class="action-col">Action</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={link <- @shortlink_list}>
                      <td class="shortlink-slug-cell"><code class="shortlink-slug-code">{link.slug}</code></td>
                      <td class="shortlink-url-cell">
                        <span class="shortlink-url-text">{Shortlink.short_url_for_slug(link.slug)}</span>
                      </td>
                      <td class="shortlink-destination-cell">
                        <span class="shortlink-destination-text">{link.destination_url}</span>
                      </td>
                      <td><span class={["badge", shortlink_redirect_badge_class(link.redirect_type)]}>{link.redirect_type}</span></td>
                      <td><span class="badge shortlink-click-badge">{link.click_count} clicks</span></td>
                      <td class="action-col">
                        <div style="display: flex; gap: 0.4rem; align-items: center;">
                          <button
                            class="shortlink-action-btn"
                            phx-click="set_shortlink_redirect_type"
                            phx-value-id={link.id}
                            phx-value-type={if link.redirect_type == 301, do: 302, else: 301}
                          >
                            Switch to {if link.redirect_type == 301, do: "302", else: "301"}
                          </button>
                          <button
                            class="shortlink-action-btn shortlink-delete-btn"
                            phx-click="delete_short_link"
                            phx-value-id={link.id}
                            style="color: #ff7b7b; border-color: #ff7b7b;"
                            onclick="if (!confirm('Hapus shortlink? Aksi ini tidak dapat dibatalkan.')) return false;"
                          >
                            Delete
                          </button>
                        </div>
                      </td>
                    </tr>
                    <tr :if={@shortlink_list == []}>
                      <td colspan="6" class="shortlink-empty-state">Belum ada shortlink.</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </section>
          <% end %>

          <%= if @current_page == :shortlink_stats do %>
            <section id="shortlink-stats" class="card-dark shortlink-shell">
              <div class="shortlink-stats-head">
                <div>
                  <h2 class="shortlink-stats-title">Shortlink Stats</h2>
                  <p class="shortlink-stats-subtitle">Pantau performa shortlink, klik terbaru, dan link paling aktif secara realtime.</p>
                </div>
                <span class="shortlink-stats-chip">Updated Live</span>
              </div>

              <div class="shortlink-kpi-grid">
                <article class="shortlink-kpi-card">
                  <p class="kpi-label">Total Link</p>
                  <p class="kpi-value">{@shortlink_stats[:total_links] || 0}</p>
                </article>
                <article class="shortlink-kpi-card">
                  <p class="kpi-label">Link Aktif</p>
                  <p class="kpi-value">{@shortlink_stats[:active_links] || 0}</p>
                </article>
                <article class="shortlink-kpi-card">
                  <p class="kpi-label">Total Clicks</p>
                  <p class="kpi-value">{@shortlink_stats[:total_clicks] || 0}</p>
                </article>
                <article class="shortlink-kpi-card">
                  <p class="kpi-label">Clicks Hari Ini</p>
                  <p class="kpi-value">{@shortlink_stats[:today_clicks] || 0}</p>
                </article>
              </div>

              <div class="shortlink-stats-grid">
                <article class="card-dark shortlink-top-card">
                  <h3>Top Links</h3>
                  <table class="shortlink-top-table">
                    <thead>
                      <tr>
                        <th>#</th>
                        <th>Slug</th>
                        <th>Clicks</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={{link, idx} <- Enum.with_index(@shortlink_stats[:top_links] || [], 1)}>
                        <td><span class="shortlink-rank-chip">{"##{idx}"}</span></td>
                        <td><code>{link.slug}</code></td>
                        <td><span class="badge shortlink-click-badge">{link.click_count}</span></td>
                      </tr>
                      <tr :if={(@shortlink_stats[:top_links] || []) == []}>
                        <td colspan="3" class="shortlink-empty-state">Belum ada data.</td>
                      </tr>
                    </tbody>
                  </table>
                </article>

                <article class="card-dark shortlink-log-card">
                  <h3>Recent Click Log</h3>
                  <div class="table-wrap shortlink-log-wrap">
                    <table class="domain-list-table shortlink-log-table">
                      <thead>
                        <tr>
                          <th>Waktu</th>
                          <th>Slug</th>
                          <th>IP</th>
                          <th>Referrer</th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr :for={click <- @shortlink_recent_clicks}>
                          <td>{format_shortlink_time(click.clicked_at)}</td>
                          <td><code>{click.short_link.slug}</code></td>
                          <td><span class="shortlink-ip-chip">{click.ip_address || "-"}</span></td>
                          <td><span class="shortlink-referrer-text">{click.referrer || "-"}</span></td>
                        </tr>
                        <tr :if={@shortlink_recent_clicks == []}>
                          <td colspan="4" class="shortlink-empty-state">Belum ada click log.</td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                </article>
              </div>
            </section>
          <% end %>

          <%= if @current_page == :shortlink_rotator do %>
            <section id="shortlink-rotator" class="card-dark shortlink-shell">
              <div class="shortlink-list-head rotator-head">
                <div class="rotator-head-main">
                  <h2 class="list-domain-title">Rotator Shortlink</h2>
                  <p class="shortlink-list-subtitle">Kelola domain fallback per shortlink. Saat domain utama terdeteksi blocked, sistem akan failover otomatis ke domain cadangan sesuai prioritas.</p>
                </div>
                <div class="rotator-metrics">
                  <span class="rotator-metric-chip">
                    <strong>{length(@shortlink_rotator_list)}</strong>
                    <small>Links</small>
                  </span>
                  <span class="rotator-metric-chip">
                    <strong>{length(@domains)}</strong>
                    <small>Domains</small>
                  </span>
                  <span class="rotator-metric-chip">
                    <strong>
                      {Enum.count(@shortlink_rotator_list, fn link ->
                        case Map.get(link, :rotator) do
                          %{enabled: true} -> true
                          _ -> false
                        end
                      end)}
                    </strong>
                    <small>Active</small>
                  </span>
                </div>
              </div>

              <div class="admin-grid profile-grid rotator-grid">
                <article class="card-dark shortlink-form-card rotator-config-card">
                  <div class="rotator-config-head">
                    <div>
                      <h3>Pengaturan Rotator</h3>
                      <p class="shortlink-card-subtitle">Pilih shortlink, atur domain fallback, lalu aktifkan failover otomatis.</p>
                      <div class="rotator-inline-stats">
                        <span class="rotator-inline-chip">Trusted Fallback: {length(@rotator_fallback_domains)}</span>
                        <span class="rotator-inline-chip">Shortlink Tersedia: {length(@shortlink_rotator_links)}</span>
                      </div>
                    </div>
                    <span class="rotator-config-pill">Failover Rules</span>
                  </div>

                  <div class="rotator-form-panel">
                    <.form for={@rotator_form} phx-submit="save_shortlink_rotator" class="shortlink-form-grid rotator-form-grid">
                      <div class="shortlink-field rotator-field-block">
                        <label>
                          Shortlink
                          <small class="rotator-label-meta">Slug sumber</small>
                        </label>
                        <select class="rotator-select" name="rotator[short_link_id]" required>
                          <option value="">Pilih Slug Shortlink</option>
                          <option
                            :for={link <- @shortlink_rotator_links}
                            value={link.id}
                            selected={to_string(@rotator_form[:short_link_id].value) == to_string(link.id)}
                          >
                            {"#{link.slug} -> #{primary_domain_from_url(link.destination_url)}"}
                          </option>
                        </select>
                      </div>

                      <div class="shortlink-field rotator-field-block">
                        <label>
                          Fallback Domain
                          <small class="rotator-label-meta">Urutan prioritas</small>
                        </label>
                        <select class="rotator-select rotator-select-multi" name="rotator[fallback_domain_ids][]" multiple size="1">
                        <option :if={@rotator_fallback_domains == []} value="" disabled={true}>Tidak ada fallback domain trusted tersedia</option>
                        <option
                          :for={domain <- @rotator_fallback_domains}
                          value={domain.id}
                          selected={to_string(domain.id) in normalize_selected_ids(@rotator_form[:fallback_domain_ids].value)}
                        >
                          {domain.name}
                          </option>
                        </select>
                        <p class="shortlink-help">Tekan Ctrl/Cmd untuk memilih lebih dari satu domain.</p>
                      </div>

                      <label class="checkbox-label rotator-checkbox">
                        <input type="checkbox" name="rotator[enabled]" value="true" checked={to_string(@rotator_form[:enabled].value) == "true"} />
                        Aktifkan rotator untuk shortlink ini
                      </label>

                      <div class="actions rotator-actions">
                        <button type="submit" class="rotator-submit-btn">Simpan Rotator</button>
                      </div>
                    </.form>
                  </div>

                </article>

                <article class="card-dark shortlink-guide-card">
                  <div class="rotator-list-headline">
                    <h3>Daftar Rotator Aktif</h3>
                    <span class="rotator-hint-chip">Auto Failover</span>
                  </div>
                  <p class="shortlink-card-subtitle">Pantau konfigurasi slug, domain utama, fallback, dan status rotator pada satu tabel.</p>
                  <.form for={to_form(%{"q" => @shortlink_rotator_query}, as: :shortlink_rotator_search)} phx-change="search_shortlink_rotator" class="list-domain-search-form shortlink-list-search-form">
                    <input
                      type="text"
                      name="shortlink_rotator_search[q]"
                      value={@shortlink_rotator_query}
                      placeholder="Cari slug atau domain..."
                      class="list-domain-search"
                      phx-debounce="250"
                      autocomplete="off"
                    />
                  </.form>

                  <div class="table-wrap rotator-table-wrap">
                    <table class="domain-list-table shortlink-table rotator-table">
                      <thead>
                        <tr>
                          <th>Slug</th>
                          <th>Primary Domain</th>
                          <th>Status</th>
                          <th class="action-col">Action</th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr :for={link <- @shortlink_rotator_list}>
                          <td><code class="rotator-slug-code">{link.slug}</code></td>
                          <td><span class="rotator-primary-domain">{primary_domain_from_url(link.destination_url)}</span></td>
                          <td>
                            <span class={["badge", "rotator-status-badge", rotator_status_badge(link)]}>{rotator_status_label(link)}</span>
                          </td>
                          <td class="action-col rotator-action-cell">
                            <button class="rotator-edit-btn" type="button" phx-click="edit_shortlink_rotator" phx-value-id={link.id}>Edit</button>
                          </td>
                        </tr>
                        <tr :if={@shortlink_rotator_list == []}>
                          <td colspan="4" class="shortlink-empty-state">Belum ada shortlink.</td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                  <p class="rotator-list-meta">Total konfigurasi: {length(@shortlink_rotator_list)}</p>
                </article>
              </div>

              <div :if={@rotator_modal_open and is_map(@rotator_modal_link)} class="rotator-modal-layer">
                <button type="button" class="rotator-modal-backdrop" phx-click="close_rotator_modal" aria-label="Tutup detail rotator"></button>
                <section class="rotator-modal-card" role="dialog" aria-modal="true" aria-label="Detail rotator">
                  <div class="rotator-modal-head">
                    <h3>Detail Rotator</h3>
                    <button type="button" class="rotator-modal-close" phx-click="close_rotator_modal">Tutup</button>
                  </div>

                  <div class="rotator-modal-grid">
                    <div class="rotator-modal-item">
                      <span class="rotator-modal-label">Slug</span>
                      <code class="rotator-modal-value">{@rotator_modal_link.slug}</code>
                    </div>
                    <div class="rotator-modal-item">
                      <span class="rotator-modal-label">Primary Domain</span>
                      <span class="rotator-modal-value">{primary_domain_from_url(@rotator_modal_link.destination_url)}</span>
                    </div>
                    <div class="rotator-modal-item">
                      <span class="rotator-modal-label">Status Rotator</span>
                      <span class={["badge", "rotator-status-badge", rotator_status_badge(@rotator_modal_link)]}>{rotator_status_label(@rotator_modal_link)}</span>
                    </div>
                  </div>

                  <div class="admin-grid profile-grid" style="margin-top: 0.85rem;">
                    <article class="card-dark">
                      <h4 style="margin: 0 0 0.5rem 0; color: #f5f9ff;">Primary Domain</h4>
                      <p class="admin-subtitle">Pilih domain tujuan utama untuk shortlink ini.</p>
                      <.form for={@rotator_primary_form} as={:rotator_primary} phx-submit="save_rotator_primary_domain">
                        <input type="hidden" name="rotator_primary[short_link_id]" value={@rotator_modal_link.id} />
                        <label>Domain Tujuan Utama</label>
                        <select class="rotator-select" name="rotator_primary[destination_domain]" required>
                          <option value="">Pilih domain tujuan</option>
                          <option
                            :for={domain <- shortlink_domain_options(@domains, @remote_domains)}
                            value={domain}
                            selected={to_string(@rotator_primary_form[:destination_domain].value) == to_string(domain)}
                          >
                            {shortlink_domain_option_label(domain)}
                          </option>
                        </select>
                        <div class="actions" style="margin-top: 0.8rem;">
                          <button type="submit" class="rotator-submit-btn">Simpan Primary Domain</button>
                        </div>
                      </.form>
                    </article>

                    <article class="card-dark">
                      <h4 style="margin: 0 0 0.5rem 0; color: #f5f9ff;">Fallback Domain</h4>
                      <p class="admin-subtitle">Atur domain failover yang dipakai jika primary domain terdeteksi blocked.</p>
                      <.form for={@rotator_form} as={:rotator} phx-submit="save_shortlink_rotator">
                        <input type="hidden" name="rotator[short_link_id]" value={@rotator_modal_link.id} />

                        <label>Daftar Fallback Domain</label>
                        <select class="rotator-select rotator-select-multi" name="rotator[fallback_domain_ids][]" multiple size="1">
                          <option :if={@rotator_fallback_domains == []} value="" disabled={true}>
                            Tidak ada fallback domain trusted tersedia
                          </option>
                          <option
                            :for={domain <- @rotator_fallback_domains}
                            value={domain.id}
                            selected={to_string(domain.id) in normalize_selected_ids(@rotator_form[:fallback_domain_ids].value)}
                          >
                            {domain.name}
                          </option>
                        </select>

                        <label class="checkbox-label rotator-checkbox" style="margin-top: 0.7rem;">
                          <input type="checkbox" name="rotator[enabled]" value="true" checked={to_string(@rotator_form[:enabled].value) == "true"} />
                          Aktifkan rotator untuk shortlink ini
                        </label>

                        <div class="actions" style="margin-top: 0.8rem;">
                          <button type="submit" class="rotator-submit-btn">Simpan Fallback</button>
                        </div>
                      </.form>

                      <p class="admin-subtitle" style="margin-top: 0.8rem;">Fallback saat ini:</p>
                      <ul style="margin: 0.3rem 0 0; padding-left: 1.1rem;">
                        <li :for={domain <- rotator_fallback_list(@rotator_modal_link)}>{domain}</li>
                        <li :if={rotator_fallback_list(@rotator_modal_link) == []}>Belum ada fallback domain.</li>
                      </ul>
                    </article>
                  </div>
                </section>
              </div>
            </section>
          <% end %>

          <%= if @current_page == :telegram do %>
            <section id="telegram-settings" class="card-dark">
              <div class="actions" style="margin-top: 0;">
                <h2 style="margin: 0;">Telegram Bot</h2>
              </div>

              <div class="admin-grid profile-grid" style="margin-top: 0.85rem;">
                <article class="card-dark">
                  <h3 style="margin: 0 0 0.5rem 0; color: #f5f9ff;">Konfigurasi</h3>
                  <.form for={@settings_form} phx-submit="save_telegram_settings">
                    <label>Telegram Bot Token</label>
                    <input
                      type="password"
                      name="settings[telegram_bot_token]"
                      placeholder="Masukkan token baru..."
                      autocomplete="off"
                    />
                    <p class="admin-subtitle" style="margin-top: 0.35rem;">
                      Token aktif: {masked_secret(@settings["telegram_bot_token"])}<br />
                      <small>Biarkan kosong jika tidak ingin mengubah</small>
                    </p>

                    <label>Group Chat ID</label>
                    <input
                      type="text"
                      name="settings[telegram_group_chat_id]"
                      value={@settings["telegram_group_chat_id"]}
                      placeholder="-100123456789"
                      autocomplete="off"
                    />
                    <p class="admin-subtitle" style="margin-top: 0.35rem;">
                      ID Group: {blank_dash(@settings["telegram_group_chat_id"])}<br />
                      <small>Gunakan format: -100... untuk group, atau ambil ID dari Bot Father</small>
                    </p>

                    <label>Private Chat ID (Opsional)</label>
                    <input
                      type="text"
                      name="settings[telegram_private_chat_id]"
                      value={@settings["telegram_private_chat_id"]}
                      placeholder="123456789"
                      autocomplete="off"
                    />
                    <p class="admin-subtitle" style="margin-top: 0.35rem;">
                      ID Private: {blank_dash(@settings["telegram_private_chat_id"])}<br />
                      <small>Opsional - untuk notifikasi ke chat pribadi. Ambil dari Bot Father</small>
                    </p>

                    <label class="checkbox-label">
                      <input type="checkbox" name="settings[telegram_notifications_enabled]" value="true" checked={@settings["telegram_notifications_enabled"] == "true"} />
                      Aktifkan Notifikasi Telegram
                    </label>

                    <label class="checkbox-label">
                      <input type="checkbox" name="settings[telegram_group_notifications_enabled]" value="true" checked={@settings["telegram_group_notifications_enabled"] == "true"} />
                      Aktifkan Notifikasi Group
                    </label>

                    <label class="checkbox-label">
                      <input type="checkbox" name="settings[telegram_private_notifications_enabled]" value="true" checked={@settings["telegram_private_notifications_enabled"] == "true"} />
                      Aktifkan Notifikasi Private
                    </label>

                    <div class="actions">
                      <button type="submit">Simpan Telegram</button>
                    </div>
                  </.form>
                </article>

                <article class="card-dark">
                  <h3 style="margin: 0 0 0.5rem 0; color: #f5f9ff;">Tes Notifikasi</h3>
                  <p class="admin-subtitle">Gunakan tombol di bawah untuk test kirim pesan ke channel Telegram.</p>
                  <div class="actions">
                    <button type="button" phx-click="test_group">Test Group</button>
                    <button type="button" phx-click="test_private">Test Private</button>
                  </div>
                  <p class="admin-subtitle" style="margin-top: 0.9rem;">
                    Notifikasi ringkasan dikirim otomatis setiap 5 menit berisi seluruh domain + waktu check.
                  </p>
                  <p class="admin-subtitle" style="margin-top: 0.4rem;">
                    Notifikasi live dikirim saat domain terdeteksi BLOCKED atau ERROR.
                  </p>
                </article>
              </div>
            </section>
          <% end %>

          <%= if @current_page == :profile do %>
            <section id="profile-overview" class="card-dark">
              <div class="actions" style="margin-top: 0;">
                <h2 style="margin: 0;">Profile Overview</h2>
              </div>

              <%= if @sflink_profiles == [] do %>
                <div class="admin-grid profile-grid" style="margin-top: 0.85rem;">
                  <article class="card-dark profile-user-blur">
                    <h3 style="margin: 0 0 0.5rem 0; color: #f5f9ff;">User Profile</h3>
                    <p class="admin-subtitle">Diperlukan minimal 1 SFLINK API Token untuk menjalankan program, silahkan tambahkan API Token.</p>
                  </article>
                  <article class="card-dark">
                    <h3 style="margin: 0 0 0.5rem 0; color: #f5f9ff;">SFLINK API Token</h3>
                    <p class="admin-subtitle">Belum ada token tersimpan.</p>
                  </article>
                </div>
              <% else %>
                <div :for={profile <- @sflink_profiles} class="admin-grid profile-grid" style="margin-top: 0.85rem;">
                  <article class="card-dark">
                    <h3 style="margin: 0 0 0.5rem 0; color: #f5f9ff;">User Profile</h3>
                    <table>
                      <tbody>
                        <tr>
                          <th>Username</th>
                          <td>{profile.name}</td>
                        </tr>
                        <tr>
                          <th>Email</th>
                          <td>{profile.email || "-"}</td>
                        </tr>
                        <tr>
                          <th>Status</th>
                          <td>
                            <span class={if profile.active, do: "badge badge-green", else: "badge badge-gray"}>
                              {if profile.active, do: "Active", else: "Inactive"}
                            </span>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </article>
                  <article class="card-dark">
                    <h3 style="margin: 0 0 0.5rem 0; color: #f5f9ff;">SFLINK API Token</h3>
                    <label>API Token</label>
                    <input
                      type="password"
                      value={profile.api_token}
                      placeholder="sf_xxxxx"
                      autocomplete="off"
                      readonly
                    />

                    <div class="actions">
                      <button type="button" phx-click="activate_sflink_profile" phx-value-id={profile.id}>Save API Token</button>
                      <button type="button" phx-click="delete_sflink_profile" phx-value-id={profile.id}>Hapus API Token</button>
                    </div>
                  </article>
                </div>
              <% end %>
            </section>

            <section id="profile-management" class="card-dark" style="margin-top: 1rem;">
              <div class="actions" style="margin-top: 0;">
                <h2 style="margin: 0;">Tambah Profile</h2>
                <span class="badge badge-blue">{length(@sflink_profiles)}/{@max_sflink_profiles}</span>
              </div>

              <div class="admin-grid profile-grid" style="margin-top: 0.85rem;">
                <article class="card-dark profile-user-blur profile-placeholder-error">
                  <h3 style="margin: 0 0 0.5rem 0; color: #f5f9ff;">User Profile</h3>
                  <div class="placeholder-center">
                    <p class="admin-subtitle placeholder-message" style="margin: 0;">Silahkan tambahkan profile dengan cara memasukan SFLINK API Token.</p>
                  </div>
                </article>

                <article class="card-dark">
                  <h3 style="margin: 0 0 0.5rem 0; color: #f5f9ff;">SFLINK API Token</h3>
                  <.form for={@sflink_profile_form} phx-submit="add_sflink_profile">
                    <label>SFLINK API Token</label>
                    <input
                      type="password"
                      name="sflink_profile[api_token]"
                      value={@sflink_profile_form[:api_token].value}
                      placeholder="sf_xxxxx"
                      autocomplete="off"
                      disabled={length(@sflink_profiles) >= @max_sflink_profiles}
                      required
                    />
                    <p :if={length(@sflink_profiles) >= @max_sflink_profiles} class="admin-subtitle" style="margin: 0.5rem 0 0;">
                      Batas maksimal 10 profile sudah tercapai.
                    </p>

                    <div class="actions">
                      <button type="submit" disabled={length(@sflink_profiles) >= @max_sflink_profiles}>Tambah Profile</button>
                    </div>
                  </.form>
                </article>
              </div>
            </section>
          <% end %>

          <%= if @current_page == :admin_manager do %>
            <section id="admin-manager" class="card-dark">
              <div class="actions" style="margin-top: 0;">
                <h2 style="margin: 0;">Admin Manager</h2>
              </div>
              <p class="admin-subtitle" style="margin-top: 0.55rem;">
                Kelola keamanan akun admin dari satu halaman: ubah password aktif dan atur channel Telegram untuk lupa password.
              </p>

              <div class="admin-grid profile-grid" style="margin-top: 0.85rem;">
                <article class="card-dark">
                  <h3 style="margin: 0 0 0.5rem 0; color: #f5f9ff;">Change Password</h3>
                  <p class="admin-subtitle">Gunakan menu ini jika Anda masih mengetahui password saat ini.</p>

                  <.form for={@admin_manager_change_form} as={:admin_manager} phx-submit="admin_manager_change_password">
                    <label>Current Password</label>
                    <input
                      type="password"
                      name="admin_manager[current_password]"
                      value={@admin_manager_change_form[:current_password].value}
                      autocomplete="current-password"
                      required
                    />

                    <label>New Password</label>
                    <input
                      type="password"
                      name="admin_manager[password]"
                      value={@admin_manager_change_form[:password].value}
                      autocomplete="new-password"
                      required
                    />

                    <label>Confirm New Password</label>
                    <input
                      type="password"
                      name="admin_manager[password_confirmation]"
                      value={@admin_manager_change_form[:password_confirmation].value}
                      autocomplete="new-password"
                      required
                    />

                    <div class="actions">
                      <button type="submit">Update Password</button>
                    </div>
                  </.form>
                </article>

                <article class="card-dark">
                  <h3 style="margin: 0 0 0.5rem 0; color: #f5f9ff;">Forgot Password Telegram Setup</h3>
                  <p class="admin-subtitle">Konfigurasi ini digunakan saat sistem mengirim OTP reset password admin.</p>

                  <.form for={@admin_manager_reset_settings_form} as={:admin_reset} phx-submit="save_admin_reset_settings">
                    <label>Bot Token (Reset Password)</label>
                    <input
                      type="password"
                      name="admin_reset[admin_reset_telegram_bot_token]"
                      value={@admin_manager_reset_settings_form[:admin_reset_telegram_bot_token].value}
                      placeholder="123456789:AA..."
                      autocomplete="off"
                      required
                    />

                    <label>Group Chat ID (Reset Password)</label>
                    <input
                      type="text"
                      name="admin_reset[admin_reset_telegram_group_chat_id]"
                      value={@admin_manager_reset_settings_form[:admin_reset_telegram_group_chat_id].value}
                      placeholder="-100xxxxxxxxxx"
                      autocomplete="off"
                      required
                    />

                    <p class="admin-subtitle" style="margin-top: 0.7rem;">
                      Nilai ini disimpan di settings aplikasi dan dipakai runtime saat fitur lupa password dijalankan.
                    </p>

                    <div class="actions">
                      <button type="submit">Simpan Konfigurasi</button>
                    </div>
                  </.form>
                </article>
              </div>
            </section>
          <% end %>
        </div>
      </div>
    </section>
    """
  end

  defp assign_domains(socket, domains) do
    assign(socket, domains: domains, stats: compute_stats(domains))
  end

  defp compute_stats(domains) do
    %{
      active: Enum.count(domains, & &1.active),
      down: Enum.count(domains, &(&1.last_status in ["down", "error"])),
      nawala: Enum.count(domains, &(&1.last_status == "nawala"))
    }
  end

  defp assign_remote_domains(socket, show_error \\ true) do
    case Monitor.list_remote_domains() do
      {:ok, domains} ->
        assign(socket, :remote_domains, domains)

      {:error, _reason} ->
        socket
        |> assign(:remote_domains, [])
        |> maybe_flash_error(show_error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")

      _ ->
        socket
        |> assign(:remote_domains, [])
        |> maybe_flash_error(show_error, "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi.")
    end
  end

  defp page_from_action(:add_domain), do: :add_domain
  defp page_from_action(:list_domain), do: :list_domain
  defp page_from_action(:status_domain), do: :status_domain
  defp page_from_action(:telegram), do: :telegram
  defp page_from_action(:profile), do: :profile
  defp page_from_action(:admin_manager), do: :admin_manager
  defp page_from_action(:shortlink_create), do: :shortlink_create
  defp page_from_action(:shortlink_list), do: :shortlink_list
  defp page_from_action(:shortlink_stats), do: :shortlink_stats
  defp page_from_action(:shortlink_rotator), do: :shortlink_rotator
  defp page_from_action(_), do: :home

  defp page_title(:add_domain), do: "Add Domain | Elixir Nawala"
  defp page_title(:list_domain), do: "List Domain | Elixir Nawala"
  defp page_title(:status_domain), do: "Domain Status | Elixir Nawala"
  defp page_title(:telegram), do: "Telegram | Elixir Nawala"
  defp page_title(:profile), do: "Profile | Elixir Nawala"
  defp page_title(:admin_manager), do: "Admin Manager | Elixir Nawala"
  defp page_title(:shortlink_create), do: "Create Shortlink | Elixir Nawala"
  defp page_title(:shortlink_list), do: "List Shortlink | Elixir Nawala"
  defp page_title(:shortlink_stats), do: "Shortlink Stats | Elixir Nawala"
  defp page_title(:shortlink_rotator), do: "Rotator Shortlink | Elixir Nawala"
  defp page_title(:home), do: "Operations Dashboard | Elixir Nawala"

  defp admin_manager_change_form do
    to_form(
      %{
        "current_password" => "",
        "password" => "",
        "password_confirmation" => ""
      },
      as: :admin_manager
    )
  end

  defp admin_manager_reset_settings_form(settings) do
    to_form(
      %{
        "admin_reset_telegram_bot_token" =>
          settings
          |> Map.get("admin_reset_telegram_bot_token", "")
          |> to_string(),
        "admin_reset_telegram_group_chat_id" =>
          settings
          |> Map.get("admin_reset_telegram_group_chat_id", "")
          |> to_string()
      },
      as: :admin_reset
    )
  end

  defp menu_class(true), do: "menu-item active"
  defp menu_class(false), do: "menu-item"

  defp submenu_class(true), do: "submenu-item active"
  defp submenu_class(false), do: "submenu-item"

  attr :name, :string, required: true
  defp nav_icon(assigns) do
    ~H"""
    <%= case @name do %>
      <% "phoenix" -> %>
        <svg viewBox="0 0 24 24" fill="none" aria-hidden="true">
          <path d="M5.7 20.6V11a6.3 6.3 0 0 1 12.6 0v9.6" fill="currentColor"/>
          <path d="M5.7 20.6c.8 0 1.4-.6 2-1.2.5.6 1.1 1.2 1.9 1.2s1.5-.6 2-1.2c.5.6 1.1 1.2 2 1.2s1.5-.6 2-1.2c.5.6 1.1 1.2 1.9 1.2" stroke="#0b1324" stroke-width="1.25" stroke-linecap="round" stroke-linejoin="round"/>
          <path d="M8.2 8.8h2.6M9.5 7.5v2.6" stroke="#0b1324" stroke-width="1.5" stroke-linecap="round"/>
          <path d="m13.7 9.4 2.9-1.6-2.9-1.6M13.7 9.4l2.9 1.6" stroke="#0b1324" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
          <path d="M8 13.7h7.9" stroke="#0b1324" stroke-width="1.5" stroke-linecap="round"/>
          <path d="M18.3 5.7c.9.5 1.5 1.4 1.6 2.5M16.8 4.5c.4 0 .8.1 1.2.2" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" opacity="0.6"/>
        </svg>
      <% "moon" -> %>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 1 0 9.8 9.8z"/>
        </svg>
      <% "bell" -> %>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M15 17H5.5l1.4-1.4A2 2 0 0 0 7.5 14V11a4.5 4.5 0 1 1 9 0v3a2 2 0 0 0 .6 1.4L18.5 17z"/>
          <path d="M10 19a2 2 0 0 0 4 0"/>
        </svg>
      <% "grid" -> %>
        <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
          <rect x="4" y="4" width="4" height="4" rx="1"></rect>
          <rect x="10" y="4" width="4" height="4" rx="1"></rect>
          <rect x="16" y="4" width="4" height="4" rx="1"></rect>
          <rect x="4" y="10" width="4" height="4" rx="1"></rect>
          <rect x="10" y="10" width="4" height="4" rx="1"></rect>
          <rect x="16" y="10" width="4" height="4" rx="1"></rect>
          <rect x="4" y="16" width="4" height="4" rx="1"></rect>
          <rect x="10" y="16" width="4" height="4" rx="1"></rect>
          <rect x="16" y="16" width="4" height="4" rx="1"></rect>
        </svg>
      <% "home" -> %>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M3 10.5 12 3l9 7.5"/>
          <path d="M5.5 9.8V20h13V9.8"/>
          <path d="M10 20v-4h4v4"/>
        </svg>
      <% "domain" -> %>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <circle cx="12" cy="12" r="8.5"/>
          <path d="M3.8 9h16.4M3.8 15h16.4M12 3.5c2.3 2.3 3.6 5.3 3.6 8.5S14.3 18.2 12 20.5M12 3.5C9.7 5.8 8.4 8.8 8.4 12S9.7 18.2 12 20.5"/>
        </svg>
      <% "telegram" -> %>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="m21 4-3.2 15.3c-.2 1-1.2 1.5-2.1 1.1L11 18l-2.4 2.2c-.6.6-1.7.2-1.8-.7L6 14 2.2 12c-.9-.5-.8-1.8.2-2.1L20 3.4c.7-.2 1.3.4 1.2 1.1z"/>
          <path d="m6.2 14 11.4-8.3"/>
        </svg>
      <% "shortlink" -> %>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M10 14a3 3 0 0 1 0-4l2-2a3 3 0 1 1 4.2 4.2l-1 1"/>
          <path d="M14 10a3 3 0 0 1 0 4l-2 2a3 3 0 1 1-4.2-4.2l1-1"/>
        </svg>
      <% "admin" -> %>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <circle cx="12" cy="8" r="3.2"/>
          <path d="M5 20c.9-3.2 3.7-5 7-5s6.1 1.8 7 5"/>
          <path d="M18.5 8.5v3M17 10h3"/>
        </svg>
      <% "collapse" -> %>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M5.5 4.5v15"/>
          <path d="M18.5 12h-9"/>
          <path d="m12.5 8-4 4 4 4"/>
        </svg>
      <% "expand" -> %>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M5.5 4.5v15"/>
          <path d="M9.5 12h9"/>
          <path d="m14.5 8 4 4-4 4"/>
        </svg>
      <% _ -> %>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true">
          <circle cx="12" cy="12" r="8"/>
        </svg>
    <% end %>
    """
  end

  defp format_reason(:missing_sflink_token), do: "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi."
  defp format_reason({:http_error, code, _message, _body}) when code in [401, 403],
    do: "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi."

  defp format_reason({:http_error, _code, _message, _body}), do: "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi."
  defp format_reason({:sflink_error, _message, _body}), do: "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi."
  defp format_reason({:invalid_response, _body}), do: "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi."
  defp format_reason(_reason), do: "Operasi gagal diproses. Periksa input dan konfigurasi layanan, lalu coba lagi."

  defp sync_remote_domains(socket) do
    case Monitor.sync_remote_domains_to_local() do
      {:ok, _} -> socket
      _ -> socket
    end
  end

  defp checker_interval_label(nil), do: "5 min"

  defp checker_interval_label(seconds) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {value, _} -> checker_interval_label(value)
      _ -> "5 min"
    end
  end

  defp checker_interval_label(seconds) when is_integer(seconds) and seconds >= 60 do
    minutes = div(seconds, 60)
    "#{minutes} min"
  end

  defp checker_interval_label(_), do: "5 min"

  attr :name, :string, required: true
  defp status_icon(assigns) do
    ~H"""
    <%= case @name do %>
      <% "shield" -> %>
        <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M10 2.2 4 4.5v4.8c0 3.5 2.3 6.8 6 8.5 3.7-1.7 6-5 6-8.5V4.5L10 2.2z"/></svg>
      <% "globe" -> %>
        <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="10" cy="10" r="7"/><path d="M3 10h14M10 3c2 2 3 4.5 3 7s-1 5-3 7c-2-2-3-4.5-3-7s1-5 3-7"/></svg>
      <% "pulse" -> %>
        <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M2.5 10h4l1.5-3 2.5 6 1.5-3h5.5"/></svg>
      <% "gear" -> %>
        <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="10" cy="10" r="2.5"/><path d="M10 2.5v2M10 15.5v2M2.5 10h2M15.5 10h2M4.6 4.6l1.4 1.4M14 14l1.4 1.4M15.4 4.6 14 6M6 14l-1.4 1.4"/></svg>
      <% "clock" -> %>
        <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="10" cy="10" r="7"/><path d="M10 6.3v4l2.5 1.5"/></svg>
      <% "link" -> %>
        <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M8 12a3 3 0 0 1 0-4l2-2a3 3 0 1 1 4.2 4.2l-1 1"/><path d="M12 8a3 3 0 0 1 0 4l-2 2a3 3 0 1 1-4.2-4.2l1-1"/></svg>
      <% "check" -> %>
        <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="10" cy="10" r="7"/><path d="m7 10.2 2 2.1 4-4"/></svg>
      <% _ -> %>
        <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="10" cy="10" r="7"/></svg>
    <% end %>
    """
  end

  defp normalized_domain_status(rd, remote_statuses) do
    Map.get(remote_statuses, remote_domain_key(rd), rd.status || "unknown")
    |> to_string()
    |> String.downcase()
  end

  defp format_added_date(nil), do: "-"
  defp format_added_date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%d %b %Y")
      _ -> value
    end
  end

  defp parse_api_datetime(nil), do: nil

  defp parse_api_datetime(value) when is_binary(value) do
    iso = String.replace(value, " ", "T")

    case NaiveDateTime.from_iso8601(iso) do
      {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
      _ -> nil
    end
  end

  defp format_api_datetime(value, format) do
    case parse_api_datetime(value) do
      %DateTime{} = dt -> Calendar.strftime(dt, format)
      _ -> "-"
    end
  end

  defp next_check_datetime(rd) do
    with %DateTime{} = dt <- parse_api_datetime(rd.last_checked),
         minutes when is_integer(minutes) <- rd.check_interval_minutes do
      DateTime.add(dt, minutes * 60, :second)
    else
      _ -> nil
    end
  end

  defp countdown_to_next_check(rd, now) do
    case next_check_datetime(rd) do
      %DateTime{} = dt ->
        sec = max(DateTime.diff(dt, api_now_for_calc(now), :second), 0)
        "#{String.pad_leading(Integer.to_string(div(sec, 60)), 2, "0")}:#{String.pad_leading(Integer.to_string(rem(sec, 60)), 2, "0")}"

      _ ->
        "00:00"
    end
  end

  defp next_check_time_from_api(rd, now) do
    case next_check_datetime(rd) do
      %DateTime{} = dt ->
        Calendar.strftime(dt, "%H:%M")

      _ ->
        Calendar.strftime(api_now_for_calc(now), "%H:%M")
    end
  end

  defp monitor_status_label(true), do: "Active"
  defp monitor_status_label("true"), do: "Active"
  defp monitor_status_label(_), do: "Inactive"

  defp monitor_status_class(status) when status in [true, "true"], do: "badge badge-green"
  defp monitor_status_class(_), do: "badge badge-gray"

  defp interval_label(minutes, _fallback) when is_integer(minutes) and minutes > 0, do: "#{minutes} min"
  defp interval_label(_, fallback), do: checker_interval_label(fallback)

  defp check_status_text(rd, remote_statuses) do
    status = normalized_domain_status(rd, remote_statuses)

    cond do
      status in ["up", "true", "trusted", "safe", "aman"] -> "TRUSTED"
      status in ["down", "false", "nawala", "blocked", "error", "diblokir"] -> "BLOCKED"
      true -> "UNKNOWN"
    end
  end

  defp check_status_class(rd, remote_statuses) do
    case check_status_text(rd, remote_statuses) do
      "TRUSTED" -> "badge-green"
      "BLOCKED" -> "badge-danger"
      _ -> "badge-gray"
    end
  end

  defp countdown_label(rd, now), do: "in #{countdown_to_next_check(rd, now)}"
  defp countdown_label_seconds(seconds) when is_integer(seconds), do: "in #{format_mm_ss(seconds)}"
  defp countdown_label_seconds(_), do: "in 00:00"

  defp relative_last_check(value, now) do
    case parse_api_datetime(value) do
      %DateTime{} = dt ->
        diff = max(DateTime.diff(api_now_for_calc(now), dt, :second), 0)

        cond do
          diff < 60 -> "Just now"
          diff < 3600 -> "#{div(diff, 60)} min ago"
          true -> "#{div(diff, 3600)} h ago"
        end

      _ ->
        "-"
    end
  end

  defp assign_next_refresh_seconds(socket) do
    seconds =
      socket.assigns.remote_domains
      |> Enum.map(&seconds_to_next_check(&1, socket.assigns.status_clock))
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> 20 end)
      |> max(1)

    assign(socket, :next_refresh_seconds, seconds)
  end

  defp seconds_to_next_check(rd, now) do
    case next_check_datetime(rd) do
      %DateTime{} = dt -> max(DateTime.diff(dt, api_now_for_calc(now), :second), 0)
      _ -> nil
    end
  end

  defp maybe_flash_error(socket, true, message), do: put_flash(socket, :error, message)
  defp maybe_flash_error(socket, false, _message), do: socket

  defp api_now_for_calc(%DateTime{} = now) do
    DateTime.add(now, @api_time_offset_seconds, :second)
  end

  defp jakarta_time(%DateTime{} = now) do
    now
    |> DateTime.add(@api_time_offset_seconds, :second)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp live_check_all_remote_domains(socket) do
    statuses =
      socket.assigns.remote_domains
      |> Monitor.live_check_remote_domains()
      |> then(&Map.merge(socket.assigns.remote_statuses, &1))

    assign(socket, :remote_statuses, statuses)
  end

  defp parse_id_param(value) when is_integer(value), do: {:ok, value}

  defp parse_id_param(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _} -> {:ok, int}
      _ -> {:error, :invalid_id}
    end
  end

  defp parse_id_param(_), do: {:error, :invalid_id}

  defp format_mm_ss(total_seconds) do
    sec = max(total_seconds, 0)
    "#{String.pad_leading(Integer.to_string(div(sec, 60)), 2, "0")}:#{String.pad_leading(Integer.to_string(rem(sec, 60)), 2, "0")}"
  end

  defp remote_domain_key(rd) when is_map(rd) do
    Map.get(rd, :domain_key) || "#{Map.get(rd, :source_profile_id, "default")}:#{Map.get(rd, :id, "unknown")}"
  end

  defp live_check_remote_domain_with_profile(remote_id, nil),
    do: Monitor.live_check_remote_domain_status(remote_id)

  defp live_check_remote_domain_with_profile(remote_id, profile_id) when is_integer(profile_id),
    do: Monitor.live_check_remote_domain_status(remote_id, profile_id)

  defp live_check_remote_domain_with_profile(remote_id, profile_id) when is_binary(profile_id) do
    case Integer.parse(profile_id) do
      {parsed, _} -> Monitor.live_check_remote_domain_status(remote_id, parsed)
      _ -> Monitor.live_check_remote_domain_status(remote_id)
    end
  end

  defp delete_remote_domain_with_profile(remote_id, nil), do: Monitor.delete_remote_domain(remote_id)

  defp delete_remote_domain_with_profile(remote_id, profile_id) when is_integer(profile_id),
    do: Monitor.delete_remote_domain(remote_id, profile_id)

  defp delete_remote_domain_with_profile(remote_id, profile_id) when is_binary(profile_id) do
    case Integer.parse(profile_id) do
      {parsed, _} -> Monitor.delete_remote_domain(remote_id, parsed)
      _ -> Monitor.delete_remote_domain(remote_id)
    end
  end

  defp blank_token?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_token?(_), do: true

  defp mask_api_token(token) when is_binary(token) do
    trimmed = String.trim(token)

    cond do
      trimmed == "" ->
        "-"

      String.length(trimmed) <= 14 ->
        trimmed

      true ->
        "#{String.slice(trimmed, 0, 10)}...#{String.slice(trimmed, -4, 4)}"
    end
  end

  defp mask_api_token(_), do: "-"

  defp assign_sflink_profile(socket) do
    profiles = Monitor.list_sflink_profiles()

    socket
    |> assign(:sflink_profiles, profiles)
    |> assign(:sflink_profile, List.last(profiles))
  end

  defp profile_field(map, keys) when is_map(map) do
    keys
    |> Enum.find_value("-", fn key ->
      value = map[key]
      if is_nil(value) or value == "", do: nil, else: to_string(value)
    end)
  end

  defp profile_field(_, _), do: "-"

  defp stat_field(map, keys) when is_map(map) do
    keys
    |> Enum.find_value("0", fn key ->
      value = map[key]

      cond do
        is_integer(value) -> Integer.to_string(value)
        is_float(value) -> :erlang.float_to_binary(value, decimals: 0)
        is_binary(value) and value != "" -> value
        true -> nil
      end
    end)
  end

  defp stat_field(_, _), do: "0"

  defp nested_field(map, keys, default) when is_map(map) and is_list(keys) do
    case get_in(map, keys) do
      nil -> default
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      value when is_float(value) -> :erlang.float_to_binary(value, decimals: 0)
      value -> to_string(value)
    end
  end

  defp nested_field(_, _, default), do: default

  defp filtered_remote_domains(remote_domains, query) do
    q = normalize_search(query)

    if q == "" do
      remote_domains
    else
      remote_domains
      |> Enum.map(fn rd ->
        {rd, domain_match_score(rd, q)}
      end)
      |> Enum.filter(fn {_rd, score} -> score > 0.0 end)
      |> Enum.sort_by(fn {rd, score} -> {-score, String.downcase(to_string(rd.domain || "")), rd.id || 0} end)
      |> Enum.map(fn {rd, _score} -> rd end)
    end
  end

  defp domain_match_score(rd, query) do
    domain = normalize_search(rd.domain)
    domain_core = normalize_search(strip_tld(domain))
    query_core = normalize_search(strip_tld(query))

    cond do
      domain == "" ->
        0.0

      domain == query ->
        5.0

      String.starts_with?(domain, query) ->
        4.0

      String.contains?(domain, query) ->
        3.0

      String.starts_with?(domain_core, query_core) and query_core != "" ->
        2.5

      String.contains?(domain_core, query_core) and query_core != "" ->
        2.0

      true ->
        similarity = max(String.jaro_distance(domain, query), String.jaro_distance(domain_core, query_core))

        if similarity >= 0.78 do
          similarity
        else
          0.0
        end
    end
  end

  defp strip_tld(value) when is_binary(value) do
    value
    |> String.split(".")
    |> List.first()
    |> Kernel.||("")
  end

  defp strip_tld(_), do: ""

  defp normalize_search(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_search(_), do: ""

  defp assign_add_domain_profiles(socket) do
    profiles = Monitor.list_add_domain_profiles()
    default_profile_id = default_add_domain_profile_id(profiles)
    current_profile_id = socket.assigns.domain_form[:profile_id].value |> to_string()

    profile_id =
      cond do
        current_profile_id != "" and
            Enum.any?(profiles, fn profile -> to_string(profile.id) == current_profile_id end) ->
          current_profile_id

        true ->
          default_profile_id
      end

    socket
    |> assign(:add_domain_profiles, profiles)
    |> assign(
      :domain_form,
      to_form(%{"name" => socket.assigns.domain_form[:name].value || "", "profile_id" => profile_id}, as: :domain)
    )
  end

  defp default_add_domain_profile_id([profile | _]), do: to_string(profile.id)
  defp default_add_domain_profile_id(_), do: ""

  defp profile_option_label(profile) when is_map(profile) do
    name = profile[:name] || "Profile"
    remaining = profile[:domains_remaining]
    limit = profile[:domains_limit]

    case {remaining, limit} do
      {r, l} when is_integer(r) and is_integer(l) -> "#{name} (sisa #{r}/#{l})"
      {r, _} when is_integer(r) -> "#{name} (sisa #{r})"
      _ -> name
    end
  end

  defp add_domain_quota_label(profiles, selected_profile_id) do
    selected =
      selected_profile_id
      |> to_string()
      |> String.trim()

    case Enum.find(profiles, fn profile -> to_string(profile.id) == selected end) do
      nil ->
        nil

      profile ->
        case {profile[:domains_remaining], profile[:domains_limit]} do
          {r, l} when is_integer(r) and is_integer(l) -> "Sisa kuota #{r} dari #{l} domain."
          {r, _} when is_integer(r) -> "Sisa kuota #{r} domain."
          _ -> "Kuota domain tersedia."
        end
    end
  end

  defp assign_shortlink_list(socket) do
    query = socket.assigns.shortlink_query || ""
    assign(socket, :shortlink_list, Shortlink.list_short_links(query))
  end

  defp assign_shortlink_stats(socket) do
    socket
    |> assign(:shortlink_stats, Shortlink.get_stats())
    |> assign(:shortlink_recent_clicks, Shortlink.list_recent_clicks(50))
  end

  defp assign_shortlink_rotator_data(socket) do
    query = socket.assigns.shortlink_rotator_query || ""
    list = Shortlink.list_rotator_configs(query)
    trusted_fallback_domains =
      trusted_rotator_fallback_domains(
        socket.assigns.domains,
        socket.assigns.remote_domains,
        socket.assigns.remote_statuses
      )

    socket
    |> assign(:shortlink_rotator_list, list)
    |> assign(:shortlink_rotator_links, Shortlink.list_rotator_configs(""))
    |> assign(:rotator_fallback_domains, trusted_fallback_domains)
  end

  defp shortlink_pattern_url do
    base = ElixirNawalaWeb.Endpoint.url() |> String.trim_trailing("/")
    "#{base}/{slug}"
  end

  defp shortlink_domain_names(domains) when is_list(domains) do
    domains
    |> Enum.map(fn
      %{name: name} -> to_string(name || "")
      value when is_binary(value) -> value
      _ -> ""
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp shortlink_domain_names(_), do: []

  defp active_shortlink_domains(domains) when is_list(domains) do
    domains
  end

  defp active_shortlink_domains(_), do: []

  defp inactive_shortlink_domains(domains) when is_list(domains) do
    []
  end

  defp inactive_shortlink_domains(_), do: []

  defp shortlink_domain_option_label(domain) when is_binary(domain), do: domain

  defp shortlink_domain_option_label(_), do: "-"

  defp shortlink_domain_options(local_domains, remote_domains) do
    shortlink_available_domain_names(local_domains, remote_domains)
  end

  defp shortlink_available_domain_names(local_domains, remote_domains) do
    local = shortlink_domain_names(local_domains)

    remote =
      remote_domains
      |> List.wrap()
      |> Enum.map(fn
        %{domain: domain} -> to_string(domain || "")
        value when is_binary(value) -> value
        _ -> ""
      end)
      |> shortlink_domain_names()

    (local ++ remote)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp shortlink_redirect_badge_class(301), do: "shortlink-redirect-permanent"
  defp shortlink_redirect_badge_class("301"), do: "shortlink-redirect-permanent"
  defp shortlink_redirect_badge_class(_), do: "shortlink-redirect-temporary"

  defp rotator_form_from_link(link) when is_map(link) do
    fallback_ids =
      case Map.get(link, :rotator) do
        nil ->
          []

        rotator ->
          rotator.rotator_domains
          |> Enum.sort_by(& &1.priority)
          |> Enum.map(&to_string(&1.domain_id))
      end

    %{
      "short_link_id" => to_string(link.id),
      "enabled" => if(Map.get(link, :rotator) && link.rotator.enabled, do: "true", else: "false"),
      "fallback_domain_ids" => fallback_ids
    }
  end

  defp rotator_form_from_link(_), do: Shortlink.new_rotator_form_defaults()

  defp rotator_primary_form_from_link(link) when is_map(link) do
    destination_domain =
      case URI.parse(to_string(Map.get(link, :destination_url, ""))) do
        %URI{host: host} when is_binary(host) and host != "" -> host
        _ -> ""
      end

    rotator_primary_form_defaults(link.id, destination_domain)
  end

  defp rotator_primary_form_from_link(_), do: rotator_primary_form_defaults()

  defp rotator_primary_form_defaults(short_link_id \\ "", destination_domain \\ "") do
    %{
      "short_link_id" => to_string(short_link_id || ""),
      "destination_domain" => to_string(destination_domain || "")
    }
  end

  defp normalize_selected_ids(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_selected_ids(value) when is_binary(value), do: [String.trim(value)]
  defp normalize_selected_ids(_), do: []

  defp primary_domain_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> "-"
    end
  end

  defp primary_domain_from_url(_), do: "-"

  defp rotator_fallback_domains(link) when is_map(link) do
    case Map.get(link, :rotator) do
      nil ->
        "-"

      rotator ->
        rotator.rotator_domains
        |> Enum.sort_by(& &1.priority)
        |> Enum.map(fn row -> row.domain && row.domain.name end)
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> "-"
          names -> Enum.join(names, ", ")
        end
    end
  end

  defp rotator_fallback_domains(_), do: "-"

  defp rotator_fallback_list(link) when is_map(link) do
    case Map.get(link, :rotator) do
      nil ->
        []

      rotator ->
        rotator.rotator_domains
        |> Enum.sort_by(& &1.priority)
        |> Enum.map(fn row -> row.domain && row.domain.name end)
        |> Enum.reject(&is_nil/1)
    end
  end

  defp rotator_fallback_list(_), do: []

  defp rotator_status_label(link) when is_map(link) do
    case Map.get(link, :rotator) do
      %{enabled: true} -> "Enabled"
      %{enabled: false} -> "Disabled"
      _ -> "Not Set"
    end
  end

  defp rotator_status_label(_), do: "Not Set"

  defp rotator_status_badge(link) when is_map(link) do
    case Map.get(link, :rotator) do
      %{enabled: true} -> "badge-green"
      %{enabled: false} -> "badge-amber"
      _ -> "badge-gray"
    end
  end

  defp rotator_status_badge(_), do: "badge-gray"

  defp trusted_rotator_fallback_domains(domains, remote_domains, remote_statuses) do
    trusted_remote_names =
      remote_domains
      |> List.wrap()
      |> Enum.filter(&(check_status_text(&1, remote_statuses) == "TRUSTED"))
      |> Enum.map(fn rd -> rd.domain end)
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.downcase/1)
      |> MapSet.new()

    domains
    |> List.wrap()
    |> Enum.filter(fn domain ->
      name =
        domain
        |> Map.get(:name, "")
        |> to_string()
        |> String.trim()
        |> String.downcase()

      Map.get(domain, :active) == true and
        (Map.get(domain, :last_status) in ["up"] or MapSet.member?(trusted_remote_names, name))
    end)
    |> Enum.sort_by(fn domain -> String.downcase(to_string(Map.get(domain, :name, ""))) end)
  end

  defp format_shortlink_time(nil), do: "-"

  defp format_shortlink_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%d-%m-%Y %H:%M:%S UTC")
  end

  defp format_shortlink_time(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> format_shortlink_time()
  end

  defp format_shortlink_time(_), do: "-"

  defp assign_home_analytics(socket, range) do
    normalized_range = normalize_home_time_range(range)
    analytics = build_home_analytics(socket, normalized_range)

    socket
    |> assign(:home_time_range, normalized_range)
    |> assign(:home_analytics, analytics)
  end

  defp normalize_home_time_range(range) when is_binary(range) do
    if Map.has_key?(@home_time_ranges, range), do: range, else: "7d"
  end

  defp normalize_home_time_range(_), do: "7d"

  defp build_home_analytics(socket, range) do
    config = home_chart_config(range)
    {bucket_starts, range_start_at, range_end_at} = build_time_buckets(config)
    bucket_keys = Enum.map(bucket_starts, &bucket_key(&1, config.unit))

    totals = current_home_totals(socket)

    clicks_map = click_counts_by_bucket(range_start_at, range_end_at, config.trunc_unit, config.unit)
    trusted_map = domain_status_by_bucket(["up"], range_start_at, range_end_at, config.trunc_unit, config.unit)
    blocked_map = domain_status_by_bucket(["down", "nawala", "error"], range_start_at, range_end_at, config.trunc_unit, config.unit)

    clicks_series = Enum.map(bucket_keys, &Map.get(clicks_map, &1, 0))
    trusted_series = Enum.map(bucket_keys, &Map.get(trusted_map, &1, 0))
    blocked_series = Enum.map(bucket_keys, &Map.get(blocked_map, &1, 0))
    domains_series = List.duplicate(totals.domains, length(bucket_keys))

    %{
      range_options: @home_time_ranges,
      totals: totals,
      status_rects: home_status_rects(totals),
      chart:
        build_chart_payload(
          bucket_starts,
          config,
          clicks_series,
          trusted_series,
          blocked_series,
          domains_series
        )
    }
  end

  defp home_chart_config("1d"), do: %{unit: :hour, trunc_unit: "hour", points: 24}
  defp home_chart_config("7d"), do: %{unit: :day, trunc_unit: "day", points: 7}
  defp home_chart_config("1m"), do: %{unit: :day, trunc_unit: "day", points: 30}
  defp home_chart_config("1y"), do: %{unit: :month, trunc_unit: "month", points: 12}
  defp home_chart_config(_), do: home_chart_config("7d")

  defp build_time_buckets(%{unit: unit, points: points}) do
    now = DateTime.utc_now()
    current_bucket = truncate_datetime(now, unit)

    bucket_starts =
      Enum.map(0..(points - 1), fn idx ->
        shift = idx - (points - 1)

        case unit do
          :month -> add_months(current_bucket, shift)
          _ -> DateTime.add(current_bucket, shift * seconds_for_unit(unit), :second)
        end
      end)

    {bucket_starts, hd(bucket_starts), now}
  end

  defp truncate_datetime(%DateTime{} = dt, :hour) do
    dt
    |> DateTime.truncate(:second)
    |> Map.put(:minute, 0)
    |> Map.put(:second, 0)
    |> Map.put(:microsecond, {0, 0})
  end

  defp truncate_datetime(%DateTime{} = dt, :day) do
    date = DateTime.to_date(dt)
    {:ok, ndt} = NaiveDateTime.new(date, ~T[00:00:00])
    DateTime.from_naive!(ndt, "Etc/UTC")
  end

  defp truncate_datetime(%DateTime{} = dt, :month) do
    date = Date.new!(dt.year, dt.month, 1)
    {:ok, ndt} = NaiveDateTime.new(date, ~T[00:00:00])
    DateTime.from_naive!(ndt, "Etc/UTC")
  end

  defp truncate_datetime(%DateTime{} = dt, _), do: truncate_datetime(dt, :day)

  defp add_months(%DateTime{} = dt, offset) when is_integer(offset) do
    total_month = dt.year * 12 + (dt.month - 1) + offset
    year = div(total_month, 12)
    month = rem(total_month, 12) + 1
    date = Date.new!(year, month, 1)
    {:ok, ndt} = NaiveDateTime.new(date, ~T[00:00:00])
    DateTime.from_naive!(ndt, "Etc/UTC")
  end

  defp seconds_for_unit(:hour), do: 3600
  defp seconds_for_unit(:day), do: 86_400
  defp seconds_for_unit(_), do: 86_400

  defp current_home_totals(socket) do
    shortlink_stats = Shortlink.get_stats()
    live_domains = List.wrap(socket.assigns.remote_domains)
    live_statuses = socket.assigns.remote_statuses || %{}
    local_domains = List.wrap(socket.assigns.domains)

    using_live? = live_domains != []

    {domain_total, trusted_count, blocked_count, source_label} =
      if using_live? do
        trusted =
          Enum.count(live_domains, fn rd ->
            check_status_text(rd, live_statuses) == "TRUSTED"
          end)

        blocked =
          Enum.count(live_domains, fn rd ->
            check_status_text(rd, live_statuses) == "BLOCKED"
          end)

        {length(live_domains), trusted, blocked, "Live Check (SFLINK API)"}
      else
        trusted =
          Enum.count(local_domains, fn domain ->
            domain.last_status
            |> to_string()
            |> String.downcase()
            |> Kernel.==("up")
          end)

        blocked =
          Enum.count(local_domains, fn domain ->
            domain.last_status
            |> to_string()
            |> String.downcase()
            |> Kernel.in(["down", "nawala", "error", "blocked"])
          end)

        {length(local_domains), trusted, blocked, "Local Last Status (fallback)"}
      end

    %{
      clicks: shortlink_stats[:total_clicks] || 0,
      domains: domain_total,
      trusted: trusted_count,
      blocked: blocked_count,
      unknown: max(domain_total - trusted_count - blocked_count, 0),
      source: source_label
    }
  end

  defp home_status_rects(totals) do
    [
      %{
        label: "Trusted",
        value: totals.trusted || 0,
        color: "#5ecf95",
        bg: "linear-gradient(180deg,#10261d,#0e1e18)",
        border: "#2d5f48"
      },
      %{
        label: "Blocked",
        value: totals.blocked || 0,
        color: "#ff7b7b",
        bg: "linear-gradient(180deg,#2a151a,#1f1115)",
        border: "#6a2e3b"
      },
      %{
        label: "Unknown",
        value: totals.unknown || 0,
        color: "#94a3b8",
        bg: "linear-gradient(180deg,#1b2232,#141a27)",
        border: "#334155"
      }
    ]
  end

  defp click_counts_by_bucket(start_at, end_at, trunc_unit, unit) do
    ShortLinkClick
    |> where([c], c.clicked_at >= ^start_at and c.clicked_at <= ^end_at)
    |> group_by([_c], fragment("1"))
    |> select([c], {fragment("date_trunc(?, ?)", ^trunc_unit, c.clicked_at), count(c.id)})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {bucket_dt, count}, acc ->
      Map.put(acc, bucket_key(bucket_dt, unit), count)
    end)
  end

  defp domain_status_by_bucket(statuses, start_at, end_at, trunc_unit, unit) when is_list(statuses) do
    CheckResult
    |> where([cr], cr.checked_at >= ^start_at and cr.checked_at <= ^end_at and cr.status in ^statuses)
    |> group_by([_cr], fragment("1"))
    |> select([cr], {fragment("date_trunc(?, ?)", ^trunc_unit, cr.checked_at), fragment("count(distinct ?)", cr.domain_id)})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {bucket_dt, count}, acc ->
      Map.put(acc, bucket_key(bucket_dt, unit), count)
    end)
  end

  defp bucket_key(value, unit) do
    value
    |> to_utc_datetime()
    |> truncate_datetime(unit)
    |> DateTime.to_iso8601()
  end

  defp to_utc_datetime(%DateTime{} = dt), do: DateTime.shift_zone!(dt, "Etc/UTC")

  defp to_utc_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")

  defp to_utc_datetime(other) when is_binary(other) do
    case DateTime.from_iso8601(other) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp to_utc_datetime(_), do: DateTime.utc_now()

  defp build_chart_payload(bucket_starts, config, clicks_series, trusted_series, blocked_series, domains_series) do
    width = 1100
    height = 320
    padding_left = 60
    padding_right = 24
    padding_top = 18
    padding_bottom = 38

    max_value =
      [clicks_series, trusted_series, blocked_series, domains_series]
      |> List.flatten()
      |> Enum.max(fn -> 0 end)
      |> max(5)

    clicks_coords = build_series_coordinates(clicks_series, max_value, width, height, padding_left, padding_right, padding_top, padding_bottom)
    trusted_coords = build_series_coordinates(trusted_series, max_value, width, height, padding_left, padding_right, padding_top, padding_bottom)
    blocked_coords = build_series_coordinates(blocked_series, max_value, width, height, padding_left, padding_right, padding_top, padding_bottom)

    %{
      width: width,
      height: height,
      padding_left: padding_left,
      padding_right: padding_right,
      padding_bottom: padding_bottom,
      y_ticks: build_y_ticks(max_value, width, height, padding_left, padding_right, padding_top, padding_bottom),
      x_labels: build_x_labels(bucket_starts, config.unit, width, padding_left, padding_right),
      series: %{
        clicks: %{
          path: build_smooth_path(clicks_coords),
          area_path: build_area_path(clicks_coords, height, padding_bottom),
          markers: clicks_coords
        },
        trusted: %{
          path: build_smooth_path(trusted_coords),
          area_path: build_area_path(trusted_coords, height, padding_bottom),
          markers: trusted_coords
        },
        blocked: %{
          path: build_smooth_path(blocked_coords),
          area_path: build_area_path(blocked_coords, height, padding_bottom),
          markers: blocked_coords
        }
      }
    }
  end

  defp build_series_coordinates(series, max_value, width, height, padding_left, padding_right, padding_top, padding_bottom) do
    count = length(series)
    plot_width = width - padding_left - padding_right
    plot_height = height - padding_top - padding_bottom

    series
    |> Enum.with_index()
    |> Enum.map(fn {value, index} ->
      x =
        if count <= 1 do
          padding_left
        else
          padding_left + index * plot_width / (count - 1)
        end

      y = padding_top + (1 - value / max_value) * plot_height
      %{x: Float.round(x, 2), y: Float.round(y, 2)}
    end)
  end

  defp build_smooth_path([]), do: ""

  defp build_smooth_path([point]) do
    "M #{point.x} #{point.y}"
  end

  defp build_smooth_path([first | _] = points) do
    {path, _last} =
      points
      |> Enum.drop(1)
      |> Enum.reduce({"M #{first.x} #{first.y}", first}, fn point, {acc, prev} ->
        cx = Float.round((prev.x + point.x) / 2, 2)
        cy = Float.round((prev.y + point.y) / 2, 2)
        {"#{acc} Q #{prev.x} #{prev.y} #{cx} #{cy}", point}
      end)

    last = List.last(points)
    "#{path} T #{last.x} #{last.y}"
  end

  defp build_area_path([], _height, _padding_bottom), do: ""

  defp build_area_path(coords, height, padding_bottom) do
    base_y = (height - padding_bottom) * 1.0 |> Float.round(2)
    first = hd(coords)
    last = List.last(coords)
    line_path = build_smooth_path(coords)

    "#{line_path} L #{last.x} #{base_y} L #{first.x} #{base_y} Z"
  end

  defp build_y_ticks(max_value, _width, height, padding_left, _padding_right, padding_top, padding_bottom) do
    steps = 4
    plot_height = height - padding_top - padding_bottom

    Enum.map(0..steps, fn idx ->
      value = round(max_value * (steps - idx) / steps)
      y = padding_top + idx * plot_height / steps

      %{
        x: padding_left - 8,
        y: y,
        label: format_number(value)
      }
    end)
  end

  defp build_x_labels(bucket_starts, unit, width, padding_left, padding_right) do
    count = length(bucket_starts)
    plot_width = width - padding_left - padding_right
    gap = max(div(count, 6), 1)

    bucket_starts
    |> Enum.with_index()
    |> Enum.filter(fn {_bucket, idx} -> rem(idx, gap) == 0 or idx == count - 1 end)
    |> Enum.map(fn {bucket, idx} ->
      x =
        if count <= 1 do
          padding_left
        else
          padding_left + idx * plot_width / (count - 1)
        end

      %{x: x, label: format_bucket_label(bucket, unit)}
    end)
  end

  defp format_bucket_label(%DateTime{} = bucket, :hour), do: Calendar.strftime(bucket, "%H:%M")
  defp format_bucket_label(%DateTime{} = bucket, :day), do: Calendar.strftime(bucket, "%d %b")
  defp format_bucket_label(%DateTime{} = bucket, :month), do: Calendar.strftime(bucket, "%b %y")
  defp format_bucket_label(_, _), do: "-"

  defp format_number(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0.")
    |> String.reverse()
  end

  defp format_number(value) when is_float(value), do: value |> round() |> format_number()
  defp format_number(_), do: "0"

  defp masked_secret(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        "-"

      String.length(trimmed) <= 8 ->
        String.duplicate("*", String.length(trimmed))

      true ->
        "#{String.slice(trimmed, 0, 4)}****#{String.slice(trimmed, -3, 3)}"
    end
  end

  defp masked_secret(_), do: "-"

  defp blank_dash(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "-"
      other -> other
    end
  end

  defp blank_dash(_), do: "-"

  defp preserve_existing_setting(value, existing_value) do
    trimmed =
      case value do
        v when is_nil(v) -> ""
        v when is_binary(v) -> String.trim(v)
        v -> v |> to_string() |> String.trim()
      end

    if trimmed == "" do
      case existing_value do
        nil -> ""
        v when is_binary(v) -> String.trim(v)
        v -> v |> to_string() |> String.trim()
      end
    else
      trimmed
    end
  end

end
