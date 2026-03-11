defmodule ElixirNawala.Monitor.SflinkProfile do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sflink_profiles" do
    field :name, :string
    field :email, :string
    field :api_token, :string
    field :active, :boolean, default: false

    timestamps()
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:name, :email, :api_token, :active])
    |> validate_required([:name, :api_token])
    |> validate_length(:name, min: 2, max: 80)
    |> validate_format(:api_token, ~r/^sf_[a-zA-Z0-9]+$/)
    |> unique_constraint(:name)
    |> unique_constraint(:api_token)
  end
end
