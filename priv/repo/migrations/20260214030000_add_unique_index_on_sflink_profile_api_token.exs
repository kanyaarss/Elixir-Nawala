defmodule ElixirNawala.Repo.Migrations.AddUniqueIndexOnSflinkProfileApiToken do
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM sflink_profiles a
    USING sflink_profiles b
    WHERE a.id > b.id
      AND a.api_token = b.api_token;
    """)

    create unique_index(:sflink_profiles, [:api_token])
  end

  def down do
    drop_if_exists unique_index(:sflink_profiles, [:api_token])
  end
end
