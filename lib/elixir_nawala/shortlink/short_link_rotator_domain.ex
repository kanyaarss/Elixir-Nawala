defmodule ElixirNawala.Shortlink.ShortLinkRotatorDomain do
  use Ecto.Schema
  import Ecto.Changeset

  schema "short_link_rotator_domains" do
    field :priority, :integer

    belongs_to :rotator, ElixirNawala.Shortlink.ShortLinkRotator
    belongs_to :domain, ElixirNawala.Monitor.Domain

    timestamps(updated_at: false)
  end

  def changeset(rotator_domain, attrs) do
    rotator_domain
    |> cast(attrs, [:rotator_id, :domain_id, :priority])
    |> validate_required([:rotator_id, :domain_id, :priority])
    |> validate_number(:priority, greater_than: 0)
    |> unique_constraint([:rotator_id, :domain_id])
    |> unique_constraint([:rotator_id, :priority])
  end
end
