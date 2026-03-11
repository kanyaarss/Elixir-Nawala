defmodule ElixirNawala.Repo.Migrations.CreateSflinkProfiles do
  use Ecto.Migration

  def change do
    create table(:sflink_profiles) do
      add :name, :string, null: false
      add :email, :string
      add :api_token, :string, null: false
      add :active, :boolean, default: false, null: false

      timestamps()
    end

    create unique_index(:sflink_profiles, [:name])
  end
end
