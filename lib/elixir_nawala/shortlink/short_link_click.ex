defmodule ElixirNawala.Shortlink.ShortLinkClick do
  use Ecto.Schema
  import Ecto.Changeset

  schema "short_link_clicks" do
    field :ip_address, :string
    field :user_agent, :string
    field :referrer, :string
    field :clicked_at, :utc_datetime_usec

    belongs_to :short_link, ElixirNawala.Shortlink.ShortLink

    timestamps(updated_at: false)
  end

  def changeset(short_link_click, attrs) do
    short_link_click
    |> cast(attrs, [:short_link_id, :ip_address, :user_agent, :referrer, :clicked_at])
    |> validate_required([:short_link_id, :clicked_at])
  end
end
