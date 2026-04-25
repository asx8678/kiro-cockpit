import Config

config :kiro_cockpit, KiroCockpit.Repo,
  username: System.get_env("KIRO_DB_USER") || "postgres",
  password: System.get_env("KIRO_DB_PASS") || "postgres",
  hostname: System.get_env("KIRO_DB_HOST") || "localhost",
  database:
    System.get_env("KIRO_DB_NAME") || "kiro_cockpit_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :kiro_cockpit, KiroCockpitWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "TEST_SECRET_KEY_BASE_32_BYTE_MINIMUM_LENGTH__",
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :kiro_cockpit, :sql_sandbox, true
