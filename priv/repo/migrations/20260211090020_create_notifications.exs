defmodule ElixirNawala.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def change do
    create table(:notifications) do
      add :domain_id, references(:domains, on_delete: :nilify_all)
      add :channel, :string, null: false
      add :event_type, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :sent_at, :utc_datetime_usec
      add :status, :string, null: false, default: "queued"

      timestamps(updated_at: false)
    end

    create index(:notifications, [:domain_id])
  end
end
