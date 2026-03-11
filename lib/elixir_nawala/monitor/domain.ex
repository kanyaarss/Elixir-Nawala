defmodule ElixirNawala.Monitor.Domain do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(up down nawala unknown error)

  schema "domains" do
    field :name, :string
    field :sflink_domain_id, :integer
    field :active, :boolean, default: true
    field :last_status, :string, default: "unknown"
    field :last_checked_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(domain, attrs) do
    domain
    |> cast(attrs, [:name, :sflink_domain_id, :active, :last_status, :last_checked_at])
    |> validate_required([:name])
    |> validate_format(:name, ~r/^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/)
    |> validate_inclusion(:last_status, @statuses)
    |> unique_constraint(:name)
    |> unique_constraint(:sflink_domain_id)
  end
end
