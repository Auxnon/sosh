import Config

# The MIX_TEST_PARTITION suffix lets tests run in parallel CI partitions.
config :sosh, Sosh.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: String.to_integer(System.get_env("DB_PORT", "5442")),
  database: "sosh_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Tests save explicitly.
config :sosh, Sosh.World, autosave_ms: nil

# Tests tick by hand (Sosh.Sim.tick/1) and load the world in Sosh.Sim.reset/1.
config :sosh, Sosh.Sim, tick_ms: nil, stage_ms: 1_000, cows: 0, autoload: false

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :sosh, SoshWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "gW1rP6sPV3yvuqdLv/14cvQ9/DLxV8yP09VloyRLJTCCl/ae7GQwCUIUABT9YbFZ",
  server: false

# In test we don't send emails
config :sosh, Sosh.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
