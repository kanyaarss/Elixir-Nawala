import Config

config :elixir_nawala, ElixirNawala.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "elixir_nawala_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :elixir_nawala, ElixirNawalaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "bNngm8HkK3Ayw8q3H4Q53GAafqnxbUI5O0j7s6zMEy2h4QfPj32g1D9m9I8w2uP4",
  watchers: []

config :elixir_nawala, ElixirNawalaWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/elixir_nawala_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :elixir_nawala, dev_routes: true

config :swoosh, :api_client, false

config :logger, level: :debug

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime
