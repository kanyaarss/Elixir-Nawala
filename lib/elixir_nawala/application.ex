defmodule ElixirNawala.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ElixirNawalaWeb.Telemetry,
      ElixirNawala.Repo,
      {DNSCluster, query: Application.get_env(:elixir_nawala, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ElixirNawala.PubSub},
      {Finch, name: ElixirNawala.Finch},
      {Oban, Application.fetch_env!(:elixir_nawala, Oban)},
      ElixirNawala.Checker.Scheduler,
      ElixirNawala.Telegram.Scheduler,
      ElixirNawalaWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: ElixirNawala.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ElixirNawalaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
