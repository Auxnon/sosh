# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :sosh,
  ecto_repos: [Sosh.Repo],
  generators: [timestamp_type: :utc_datetime]

# Start every universe of the grid on boot (making the first two if there
# are none).
config :sosh, Sosh.Universes, boot: true

# Each universe: ticks every tick_ms while anyone is in it; a crop growth
# stage takes stage_ms of world time (three stages to ripe); cows roam its
# home island. Empty for sleep_after_ms, it saves and sleeps, running
# ambient systems every idle_ms. Awake, it saves every save_ms (nil: only
# on sleep and shutdown).
config :sosh, Sosh.Sim,
  tick_ms: 100,
  stage_ms: 60_000,
  cows: 5,
  idle_ms: 2_000,
  sleep_after_ms: 10_000,
  save_ms: 30_000

# Configures the endpoint
config :sosh, SoshWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SoshWeb.ErrorHTML, json: SoshWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Sosh.PubSub,
  live_view: [signing_salt: "+xaKzW/t"]

# secret_key_base: "your_secret_key_here",
# render_errors: [view: SoshWeb.ErrorView, accepts: ~w(html json)],

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :sosh, Sosh.Mailer, adapter: Swoosh.Adapters.Local

config :mime, :types, %{
  "application/javascript" => ["js"],
  "text/javascript" => ["js"],
  "text/html" => ["js"],
  "models/gltf+json" => ["gltf"],
  "models/gltf-binary" => ["glb"]
}

# # Configure esbuild (the version is required)
# config :esbuild,
#   version: "0.17.11",
#   sosh: [
#     args:
#       ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
#     cd: Path.expand("../assets", __DIR__),
#     env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
#   ]
#
# # Configure tailwind (the version is required)
# config :tailwind,
#   version: "3.4.3",
#   sosh: [
#     args: ~w(
#       --config=tailwind.config.js
#       --input=css/app.css
#       --output=../priv/static/assets/app.css
#     ),
#     cd: Path.expand("../assets", __DIR__)
#   ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
