defmodule KiroCockpit.Application do
  @moduledoc """
  OTP Application specification for KiroCockpit.

  Supervision tree per §5.2 of the platform plan:
  - Repo (Ecto)
  - Telemetry (metrics collection)
  - PubSub (real-time messaging)
  - Endpoint (HTTP/WebSocket server)

  Domain processes (ACP transport, EventStore, NanoPlanner, etc.)
  will be added in subsequent issues as children here.
  """
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        KiroCockpit.Repo,
        {Phoenix.PubSub, name: KiroCockpit.PubSub},
        KiroCockpitWeb.Telemetry,
        KiroCockpitWeb.Endpoint
      ] ++ env_children(Mix.env())

    opts = [strategy: :one_for_one, name: KiroCockpit.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp env_children(:dev), do: [{Phoenix.LiveReloader.Socket, []}]
  defp env_children(_), do: []

  @impl true
  def config_change(changed, _new, removed) do
    KiroCockpitWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
