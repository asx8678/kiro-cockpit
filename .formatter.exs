[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["priv/repo/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}"]
]
