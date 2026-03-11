defmodule ElixirNawala.Repo.Migrations.AddAdminSessionVersionAndSecurityLogs do
  use Ecto.Migration

  def change do
    alter table(:admins) do
      add :session_version, :integer, null: false, default: 1
    end

    create table(:admin_security_logs) do
      add :admin_id, references(:admins, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :status, :string, null: false
      add :ip_address, :string
      add :user_agent, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(updated_at: false)
    end

    create index(:admin_security_logs, [:admin_id])
    create index(:admin_security_logs, [:event_type])
    create index(:admin_security_logs, [:status])
  end
end
