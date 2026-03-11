defmodule ElixirNawala.Accounts.AdminPasswordReset do
  use Ecto.Schema
  import Ecto.Changeset

  schema "admin_password_resets" do
    field :request_token_hash, :string
    field :otp_hash, :string
    field :confirmation_code_hash, :string
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec
    field :attempts, :integer, default: 0
    field :requested_ip, :string
    field :requested_user_agent, :string
    field :telegram_confirmed_at, :utc_datetime_usec
    field :telegram_confirmed_by_user_id, :string
    field :telegram_confirmed_chat_id, :string

    belongs_to :admin, ElixirNawala.Accounts.Admin

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(reset, attrs) do
    reset
    |> cast(attrs, [
      :admin_id,
      :request_token_hash,
      :otp_hash,
      :confirmation_code_hash,
      :expires_at,
      :used_at,
      :attempts,
      :requested_ip,
      :requested_user_agent,
      :telegram_confirmed_at,
      :telegram_confirmed_by_user_id,
      :telegram_confirmed_chat_id
    ])
    |> validate_required([
      :admin_id,
      :request_token_hash,
      :otp_hash,
      :confirmation_code_hash,
      :expires_at
    ])
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> unique_constraint(:request_token_hash)
  end
end
