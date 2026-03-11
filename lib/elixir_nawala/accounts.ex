defmodule ElixirNawala.Accounts do
  import Ecto.Query, warn: false

  alias ElixirNawala.Accounts.{Admin, AdminPasswordReset}
  alias ElixirNawala.Monitor
  alias ElixirNawala.Repo

  @default_otp_ttl_seconds 900
  @default_otp_max_attempts 5

  def get_admin!(id), do: Repo.get!(Admin, id)
  def get_admin(id), do: Repo.get(Admin, id)

  def get_admin_by_email(email) when is_binary(email) do
    Repo.get_by(Admin, email: normalize_email(email))
  end

  def register_admin(attrs), do: %Admin{} |> Admin.registration_changeset(attrs) |> Repo.insert()

  def authenticate_admin(email, password) when is_binary(email) and is_binary(password) do
    case get_admin_by_email(email) do
      %Admin{} = admin ->
        if Pbkdf2.verify_pass(password, admin.password_hash), do: {:ok, admin}, else: :error

      _ ->
        Pbkdf2.no_user_verify()
        :error
    end
  end

  def change_admin_password(%Admin{} = admin, current_password, new_password, confirmation)
      when is_binary(current_password) and is_binary(new_password) and is_binary(confirmation) do
    cond do
      String.trim(new_password) == "" ->
        {:error, :password_required}

      new_password != confirmation ->
        {:error, :password_confirmation_mismatch}

      not Pbkdf2.verify_pass(current_password, admin.password_hash) ->
        {:error, :invalid_current_password}

      true ->
        admin
        |> Admin.update_changeset(%{email: admin.email, password: String.trim(new_password)})
        |> Repo.update()
    end
  end

  def start_admin_password_reset(email, metadata \\ %{}) when is_binary(email) and is_map(metadata) do
    case get_admin_by_email(email) do
      %Admin{} = admin ->
        request_token = random_token(32)
        otp = random_numeric_code(6)
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        expires_at =
          now
          |> DateTime.add(admin_reset_otp_ttl_seconds(), :second)

        attrs = %{
          admin_id: admin.id,
          request_token_hash: sha256_hex(request_token),
          otp_hash: Pbkdf2.hash_pwd_salt(otp),
          expires_at: expires_at,
          requested_ip: Map.get(metadata, :ip_address),
          requested_user_agent: Map.get(metadata, :user_agent),
          confirmation_code_hash: sha256_hex(random_token(16))
        }

        with {:ok, _reset} <- create_admin_password_reset(admin.id, attrs, now),
             :ok <- send_admin_reset_otp(admin, otp) do
          {:ok, request_token}
        else
          {:error, _} = error -> error
        end

      _ ->
        Pbkdf2.no_user_verify()
        {:ok, nil}
    end
  end

  def reset_admin_password(request_token, otp, new_password, metadata \\ %{})
      when is_binary(request_token) and is_binary(otp) and is_binary(new_password) and is_map(metadata) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    max_attempts = admin_reset_otp_max_attempts()

    case get_reset_by_request_token(request_token) do
      nil ->
        {:error, :invalid_or_expired}

      %AdminPasswordReset{} = reset ->
        cond do
          not is_nil(reset.used_at) ->
            {:error, :invalid_or_expired}

          DateTime.compare(reset.expires_at, now) in [:lt, :eq] ->
            {:error, :expired}

          reset.attempts >= max_attempts ->
            {:error, :too_many_attempts}

          not Pbkdf2.verify_pass(String.trim(otp), reset.otp_hash) ->
            increment_reset_attempts(reset, now, max_attempts)
            {:error, :invalid_otp}

          true ->
            finalize_password_reset(reset, new_password, metadata, now)
        end
    end
  end

  def admin_reset_otp_ttl_seconds do
    Application.get_env(:elixir_nawala, :admin_reset_otp_ttl_seconds, @default_otp_ttl_seconds)
    |> normalize_positive_integer(@default_otp_ttl_seconds)
  end

  def admin_reset_otp_max_attempts do
    Application.get_env(:elixir_nawala, :admin_reset_otp_max_attempts, @default_otp_max_attempts)
    |> normalize_positive_integer(@default_otp_max_attempts)
  end

  defp create_admin_password_reset(admin_id, attrs, now) when is_integer(admin_id) and is_map(attrs) do
    Repo.transaction(fn ->
      from(r in AdminPasswordReset, where: r.admin_id == ^admin_id and is_nil(r.used_at))
      |> Repo.update_all(set: [used_at: now])

      %AdminPasswordReset{}
      |> AdminPasswordReset.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, reset} -> reset
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, reset} -> {:ok, reset}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_reset_by_request_token(request_token) when is_binary(request_token) do
    request_token_hash = request_token |> String.trim() |> sha256_hex()

    AdminPasswordReset
    |> where([r], r.request_token_hash == ^request_token_hash)
    |> order_by([r], desc: r.inserted_at)
    |> preload(:admin)
    |> limit(1)
    |> Repo.one()
  end

  defp finalize_password_reset(%AdminPasswordReset{} = reset, new_password, metadata, now) do
    Repo.transaction(fn ->
      with %Admin{} = admin <- Repo.get(Admin, reset.admin_id),
           {:ok, _updated_admin} <-
             admin
             |> Admin.update_changeset(%{email: admin.email, password: String.trim(new_password)})
             |> Repo.update(),
           {:ok, _updated_reset} <-
             reset
             |> Ecto.Changeset.change(%{
               used_at: now,
               telegram_confirmed_at: now,
               telegram_confirmed_by_user_id: Map.get(metadata, :telegram_user_id),
               telegram_confirmed_chat_id: Map.get(metadata, :telegram_chat_id)
             })
             |> Repo.update() do
        :ok
      else
        nil -> Repo.rollback(:admin_not_found)
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, reason} -> {:error, reason}
    end
  end

  defp increment_reset_attempts(%AdminPasswordReset{} = reset, now, max_attempts) do
    next_attempts = reset.attempts + 1
    used_at = if next_attempts >= max_attempts, do: now, else: nil

    reset
    |> Ecto.Changeset.change(%{attempts: next_attempts, used_at: used_at})
    |> Repo.update()
  end

  defp send_admin_reset_otp(%Admin{} = admin, otp) when is_binary(otp) do
    settings = Monitor.list_settings()

    bot_token = reset_setting_or_env(settings, "admin_reset_telegram_bot_token", :admin_reset_telegram_bot_token)
    chat_id = reset_setting_or_env(settings, "admin_reset_telegram_group_chat_id", :admin_reset_telegram_group_chat_id)

    cond do
      bot_token == "" or chat_id == "" ->
        {:error, :missing_reset_telegram_config}

      true ->
        message = """
        [ADMIN RESET OTP]
        Email: #{admin.email}
        OTP: #{otp}
        Berlaku: #{admin_reset_otp_ttl_seconds()} detik
        """

        url = "https://api.telegram.org/bot#{bot_token}/sendMessage"

        case Req.post(url, json: %{chat_id: chat_id, text: String.trim(message)}) do
          {:ok, %{status: status}} when status in 200..299 -> :ok
          {:ok, %{status: status, body: body}} -> {:error, {:telegram_error, status, body}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp reset_setting_or_env(settings, setting_key, env_key)
       when is_map(settings) and is_binary(setting_key) and is_atom(env_key) do
    from_settings =
      settings
      |> Map.get(setting_key, "")
      |> to_string()
      |> String.trim()

    if from_settings != "" do
      from_settings
    else
      Application.get_env(:elixir_nawala, env_key, "")
      |> to_string()
      |> String.trim()
    end
  end

  defp random_token(size) when is_integer(size) and size > 0 do
    :crypto.strong_rand_bytes(size)
    |> Base.url_encode64(padding: false)
  end

  defp random_numeric_code(digits) when is_integer(digits) and digits > 0 do
    max = :math.pow(10, digits) |> round()
    value = :rand.uniform(max) - 1
    value |> Integer.to_string() |> String.pad_leading(digits, "0")
  end

  defp sha256_hex(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp normalize_email(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_email(_), do: ""

  defp normalize_positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, fallback) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _} when int > 0 -> int
      _ -> fallback
    end
  end

  defp normalize_positive_integer(_, fallback), do: fallback
end
