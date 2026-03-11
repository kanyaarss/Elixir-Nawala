alias ElixirNawala.Repo
alias ElixirNawala.Accounts.Admin
alias ElixirNawala.Monitor.Setting

admin_email = System.get_env("DEFAULT_ADMIN_EMAIL") || "admin@nawala.local"
admin_password = System.get_env("DEFAULT_ADMIN_PASSWORD") || "ChangeMe123!"

unless Repo.get_by(Admin, email: admin_email) do
  %Admin{}
  |> Admin.registration_changeset(%{email: admin_email, password: admin_password})
  |> Repo.insert!()
end

defaults = %{
  "checker_interval_seconds" => "300",
  "sflink_base_url" => "https://app.sflink.id",
  "telegram_group_chat_id" => "",
  "telegram_private_chat_id" => "",
  "telegram_notifications_enabled" => "true"
}

Enum.each(defaults, fn {key, value} ->
  case Repo.get_by(Setting, key: key) do
    nil -> Repo.insert!(%Setting{key: key, value: value})
    _ -> :ok
  end
end)
