defmodule KiroCockpit.Repo do
  @moduledoc """
  Ecto repository for KiroCockpit.

  Per §4.1: Domain truth is persistent. Postgres is the source of truth;
  process state is cache or coordination artifact.
  """
  use Ecto.Repo,
    otp_app: :kiro_cockpit,
    adapter: Ecto.Adapters.Postgres

  def init(_type, config) do
    {:ok, Keyword.put(config, :migration_timestamps, type: :utc_datetime_usec)}
  end
end
