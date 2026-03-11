defmodule ElixirNawala.Repo do
  use Ecto.Repo,
    otp_app: :elixir_nawala,
    adapter: Ecto.Adapters.Postgres
end

