defmodule ElixirNawala.Shortlink.ShortLink do
  use Ecto.Schema
  import Ecto.Changeset

  schema "short_links" do
    field :slug, :string
    field :destination_url, :string
    field :redirect_type, :integer, default: 302
    field :active, :boolean, default: true
    field :click_count, :integer, default: 0
    field :last_clicked_at, :utc_datetime_usec

    belongs_to :created_by_admin, ElixirNawala.Accounts.Admin
    has_many :clicks, ElixirNawala.Shortlink.ShortLinkClick
    has_one :rotator, ElixirNawala.Shortlink.ShortLinkRotator

    timestamps()
  end

  def changeset(short_link, attrs) do
    short_link
    |> cast(attrs, [:slug, :destination_url, :redirect_type, :active, :created_by_admin_id])
    |> validate_required([:slug, :destination_url, :redirect_type])
    |> update_change(:slug, &normalize_slug/1)
    |> validate_format(:slug, ~r/^[a-zA-Z0-9_-]+$/)
    |> validate_length(:slug, min: 4, max: 80)
    |> validate_length(:destination_url, min: 10, max: 2000)
    |> validate_format(:destination_url, ~r/^https?:\/\//i)
    |> validate_inclusion(:redirect_type, [301, 302])
    |> unique_constraint(:slug)
  end

  def redirect_type_changeset(short_link, attrs) do
    short_link
    |> cast(attrs, [:redirect_type])
    |> validate_required([:redirect_type])
    |> validate_inclusion(:redirect_type, [301, 302])
  end

  defp normalize_slug(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_slug(value), do: value
end
