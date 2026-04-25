defmodule KiroCockpitWeb.Router do
  use KiroCockpitWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KiroCockpitWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", KiroCockpitWeb do
    pipe_through :browser

    get "/", PageController, :home

    live "/sessions/:id/plan", SessionPlanLive
  end

  if Application.compile_env(:kiro_cockpit, :dev_routes, false) do
    import Phoenix.LiveDashboard.Router

    scope "/" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: KiroCockpitWeb.Telemetry
    end
  end
end
