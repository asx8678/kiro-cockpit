import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6"), do: [:inet6], else: []

  # SSL can be enabled via DATABASE_URL query params or by setting DATABASE_SSL=true
  # SSL verification is NOT disabled by default - use only with valid certificates
  ssl_enabled? = System.get_env("DATABASE_SSL") == "true"

  repo_config = [
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6
  ]

  # Merge SSL option at top level (not in socket_options) when enabled
  repo_config = if ssl_enabled?, do: Keyword.put(repo_config, :ssl, true), else: repo_config

  config :kiro_cockpit, KiroCockpit.Repo, repo_config

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :kiro_cockpit, KiroCockpitWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base,
    cache_static_manifest: "priv/static/cache_manifest.json"

  # Enable the server conditionally via PHX_SERVER=true
  if System.get_env("PHX_SERVER") == "true" do
    config :kiro_cockpit, KiroCockpitWeb.Endpoint, server: true
  end
end
