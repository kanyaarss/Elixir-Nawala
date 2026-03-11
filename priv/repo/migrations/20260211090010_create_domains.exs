defmodule ElixirNawala.Repo.Migrations.CreateDomains do
  use Ecto.Migration

  def change do
    create table(:domains) do
      add :name, :string, null: false
      add :active, :boolean, null: false, default: true
      add :last_status, :string, null: false, default: "unknown"
      add :last_checked_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:domains, [:name])
  end
end
