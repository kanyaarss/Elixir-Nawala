defmodule ElixirNawala.Monitor.Notification do
  use Ecto.Schema
  import Ecto.Changeset

  schema "notifications" do
    field :channel, :string
    field :event_type, :string
    field :payload, :map
    field :sent_at, :utc_datetime_usec
    field :status, :string, default: "queued"

    belongs_to :domain, ElixirNawala.Monitor.Domain

    timestamps(updated_at: false)
  end

  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:domain_id, :channel, :event_type, :payload, :sent_at, :status])
    |> validate_required([:channel, :event_type, :status])
  end
end

