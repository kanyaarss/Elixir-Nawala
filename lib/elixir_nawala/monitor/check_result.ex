defmodule ElixirNawala.Monitor.CheckResult do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(up down nawala unknown error)

  schema "check_results" do
    field :status, :string
    field :raw_payload, :map, default: %{}
    field :checked_at, :utc_datetime_usec
    field :latency_ms, :integer
    field :request_id, :string

    belongs_to :domain, ElixirNawala.Monitor.Domain
  end

  def changeset(check_result, attrs) do
    check_result
    |> cast(attrs, [:domain_id, :status, :raw_payload, :checked_at, :latency_ms, :request_id])
    |> validate_required([:domain_id, :status, :checked_at, :request_id])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:request_id)
  end
end
