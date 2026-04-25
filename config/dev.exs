import Config

config :kiro_cockpit, dev_routes: true

config :kiro_cockpit, KiroCockpit.Repo,
  username: System.get_env("KIRO_DB_USER") || "postgres",
  password: System.get_env("KIRO_DB_PASS") || "postgres",
  hostname: System.get_env("KIRO_DB_HOST") || "localhost",
  database: System.get_env("KIRO_DB_NAME") || "kiro_cockpit_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :kiro_cockpit, KiroCockpitWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    "this_is_a_64_byte_development_secret_key_base_for_dev_use_only_12345678901234567890",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:default, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:default, ~w(--watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/kiro_cockpit_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :logger, :console, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
