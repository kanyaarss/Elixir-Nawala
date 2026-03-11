defmodule ElixirNawala.Repo.Migrations.CreateAdminPasswordResets do
  use Ecto.Migration

  def change do
    create table(:admin_password_resets) do
      add :admin_id, references(:admins, on_delete: :delete_all), null: false
      add :request_token_hash, :string, null: false
      add :otp_hash, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec
      add :attempts, :integer, null: false, default: 0
      add :requested_ip, :string
      add :requested_user_agent, :text

      timestamps(updated_at: false)
    end

    create index(:admin_password_resets, [:admin_id])
    create unique_index(:admin_password_resets, [:request_token_hash])
    create index(:admin_password_resets, [:expires_at])
  end
end
