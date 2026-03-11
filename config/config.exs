import Config

config :elixir_nawala,
  ecto_repos: [ElixirNawala.Repo],
  admin_session_idle_timeout_seconds: 60 * 60

config :elixir_nawala, ElixirNawalaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ElixirNawalaWeb.ErrorHTML, json: ElixirNawalaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ElixirNawala.PubSub,
  live_view: [signing_salt: "A8wSQadD"]

config :elixir_nawala, ElixirNawala.Mailer, adapter: Swoosh.Adapters.Local

config :esbuild,
  version: "0.21.5",
  elixir_nawala: [
    args: ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__)
  ]

config :tailwind,
  version: "3.4.4",
  elixir_nawala: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :elixir_nawala, Oban,
  repo: ElixirNawala.Repo,
  plugins: [{Oban.Plugins.Pruner, max_age: 60 * 60 * 24}],
  queues: [default: 20, checker: 40, notifications: 20]

config :elixir_nawala, ElixirNawala.Telegram.Client, base_url: "https://api.telegram.org"

import_config "#{config_env()}.exs"
