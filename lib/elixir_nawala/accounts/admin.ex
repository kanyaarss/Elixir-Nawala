defmodule ElixirNawala.Accounts.Admin do
  use Ecto.Schema
  import Ecto.Changeset

  schema "admins" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :password_hash, :string, redact: true

    timestamps()
  end

  def registration_changeset(admin, attrs) do
    admin
    |> cast(attrs, [:email, :password])
    |> validate_required([:email, :password])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> validate_length(:password, min: 8, max: 72)
    |> unique_constraint(:email)
    |> put_password_hash()
  end

  def update_changeset(admin, attrs) do
    admin
    |> cast(attrs, [:email, :password])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> maybe_put_password_hash()
    |> unique_constraint(:email)
  end

  defp maybe_put_password_hash(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      _ -> put_password_hash(changeset)
    end
  end

  defp put_password_hash(changeset) do
    if password = get_change(changeset, :password) do
      changeset
      |> validate_length(:password, min: 8, max: 72)
      |> put_change(:password_hash, Pbkdf2.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end
end

