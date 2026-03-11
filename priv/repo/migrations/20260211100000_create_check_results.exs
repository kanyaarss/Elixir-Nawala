defmodule ElixirNawala.Repo.Migrations.CreateCheckResults do
  use Ecto.Migration

  def change do
    create table(:check_results) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :status, :string, null: false
      add :raw_payload, :map, null: false, default: %{}
      add :checked_at, :utc_datetime_usec, null: false
      add :latency_ms, :integer
      add :request_id, :string, null: false
    end

    create index(:check_results, [:domain_id])
    create index(:check_results, [:checked_at])
    create unique_index(:check_results, [:request_id])
  end
end
