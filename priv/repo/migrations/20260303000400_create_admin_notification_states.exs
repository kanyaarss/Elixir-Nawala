defmodule ElixirNawala.Repo.Migrations.CreateAdminNotificationStates do
  use Ecto.Migration

  def change do
    create table(:admin_notification_states) do
      add :admin_id, references(:admins, on_delete: :delete_all), null: false
      add :notification_key, :string, null: false
      add :acked_at, :utc_datetime_usec
      add :muted_until, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:admin_notification_states, [:admin_id, :notification_key])
    create index(:admin_notification_states, [:admin_id])
    create index(:admin_notification_states, [:muted_until])
  end
end
