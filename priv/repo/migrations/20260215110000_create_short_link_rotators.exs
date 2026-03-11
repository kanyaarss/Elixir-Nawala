defmodule ElixirNawala.Repo.Migrations.CreateShortLinkRotators do
  use Ecto.Migration

  def change do
    create table(:short_link_rotators) do
      add :short_link_id, references(:short_links, on_delete: :delete_all), null: false
      add :enabled, :boolean, null: false, default: true

      timestamps()
    end

    create unique_index(:short_link_rotators, [:short_link_id])

    create table(:short_link_rotator_domains) do
      add :rotator_id, references(:short_link_rotators, on_delete: :delete_all), null: false
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :priority, :integer, null: false

      timestamps(updated_at: false)
    end

    create unique_index(:short_link_rotator_domains, [:rotator_id, :domain_id])
    create unique_index(:short_link_rotator_domains, [:rotator_id, :priority])
    create index(:short_link_rotator_domains, [:domain_id])
  end
end
