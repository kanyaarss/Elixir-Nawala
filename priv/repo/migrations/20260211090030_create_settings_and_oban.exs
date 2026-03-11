defmodule ElixirNawala.Repo.Migrations.CreateSettingsAndOban do
  use Ecto.Migration

  def up do
    create table(:settings) do
      add :key, :string, null: false
      add :value, :text, null: false
      timestamps()
    end

    create unique_index(:settings, [:key])

    Oban.Migrations.up(version: 12)
  end

  def down do
    Oban.Migrations.down(version: 12)
    drop table(:settings)
  end
end
