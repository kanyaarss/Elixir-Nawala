defmodule ElixirNawala.Repo.Migrations.AddSflinkDomainIdToDomains do
  use Ecto.Migration

  def change do
    alter table(:domains) do
      add :sflink_domain_id, :integer
    end

    create unique_index(:domains, [:sflink_domain_id], where: "sflink_domain_id IS NOT NULL")
  end
end
