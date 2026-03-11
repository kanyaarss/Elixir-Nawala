import Config

config :elixir_nawala, ElixirNawalaWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

config :swoosh, api_client: Swoosh.ApiClient.Finch, finch_name: ElixirNawala.Finch

config :logger, level: :info
