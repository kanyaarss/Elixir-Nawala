defmodule ElixirNawala.Shortlink.ShortLinkRotator do
  use Ecto.Schema
  import Ecto.Changeset

  schema "short_link_rotators" do
    field :enabled, :boolean, default: true

    belongs_to :short_link, ElixirNawala.Shortlink.ShortLink
    has_many :rotator_domains, ElixirNawala.Shortlink.ShortLinkRotatorDomain, foreign_key: :rotator_id

    timestamps()
  end

  def changeset(rotator, attrs) do
    rotator
    |> cast(attrs, [:short_link_id, :enabled])
    |> validate_required([:short_link_id])
    |> unique_constraint(:short_link_id)
  end
end
