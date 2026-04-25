import Config

config :kiro_cockpit,
  ecto_repos: [KiroCockpit.Repo],
  generators: [timestamp_type: :utc_datetime_usec]

config :kiro_cockpit, KiroCockpitWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: KiroCockpitWeb.ErrorHTML, json: KiroCockpitWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: KiroCockpit.PubSub,
  live_view: [signing_salt: "TEMP_SIGNING_SALT_CHANGE_IN_RUNTIME"]

config :esbuild,
  version: "0.17.11",
  kiro_cockpit: [
    args: ~w(
      js/app.js
      --bundle
      --target=es2020
      --outdir=../priv/static/assets
      --external:/fonts/*
      --external:/images/*
    ),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.4.0",
  kiro_cockpit: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
