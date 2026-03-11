defmodule ElixirNawala.Repo.Migrations.AddConfirmationFieldsToAdminPasswordResets do
  use Ecto.Migration

  def change do
    alter table(:admin_password_resets) do
      add :confirmation_code_hash, :string
      add :telegram_confirmed_at, :utc_datetime_usec
      add :telegram_confirmed_by_user_id, :string
      add :telegram_confirmed_chat_id, :string
    end

    execute(
      """
      UPDATE admin_password_resets
      SET confirmation_code_hash = request_token_hash
      WHERE confirmation_code_hash IS NULL
      """,
      "SELECT 1"
    )

    alter table(:admin_password_resets) do
      modify :confirmation_code_hash, :string, null: false
    end
  end
end
