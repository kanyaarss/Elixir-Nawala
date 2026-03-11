defmodule ElixirNawala.Repo.Migrations.CreateShortLinksAndClicks do
  use Ecto.Migration

  def change do
    create table(:short_links) do
      add :slug, :string, null: false
      add :destination_url, :text, null: false
      add :redirect_type, :integer, null: false, default: 302
      add :active, :boolean, null: false, default: true
      add :click_count, :integer, null: false, default: 0
      add :last_clicked_at, :utc_datetime_usec
      add :created_by_admin_id, references(:admins, on_delete: :nilify_all)

      timestamps()
    end

    create unique_index(:short_links, [:slug])
    create index(:short_links, [:created_by_admin_id])
    create index(:short_links, [:inserted_at])

    create table(:short_link_clicks) do
      add :short_link_id, references(:short_links, on_delete: :delete_all), null: false
      add :ip_address, :string
      add :user_agent, :text
      add :referrer, :text
      add :clicked_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false)
    end

    create index(:short_link_clicks, [:short_link_id])
    create index(:short_link_clicks, [:clicked_at])
  end
end
