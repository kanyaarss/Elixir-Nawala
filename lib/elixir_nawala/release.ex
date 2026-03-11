defmodule ElixirNawala.Release do
  @moduledoc false

  @app :elixir_nawala

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def seed_default_admin do
    load_app()

    email = System.get_env("DEFAULT_ADMIN_EMAIL") || "admin@nawala.local"
    password = System.get_env("DEFAULT_ADMIN_PASSWORD") || "ChangeMe123!"

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo_conn ->
          case repo_conn.get_by(ElixirNawala.Accounts.Admin, email: email) do
            nil ->
              %ElixirNawala.Accounts.Admin{}
              |> ElixirNawala.Accounts.Admin.registration_changeset(%{
                email: email,
                password: password
              })
              |> repo_conn.insert!()

            _ ->
              :ok
          end
        end)
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
