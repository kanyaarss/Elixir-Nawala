defmodule ElixirNawalaWeb.Router do
  use ElixirNawalaWeb, :router

  import ElixirNawalaWeb.AdminAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ElixirNawalaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_admin
  end

  pipeline :require_admin do
    plug :require_authenticated_admin
  end

  scope "/", ElixirNawalaWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/:slug", ShortlinkRedirectController, :show
    get "/admin/login", AdminSessionController, :new
    post "/admin/login", AdminSessionController, :create
    get "/admin/logout", AdminSessionController, :delete
    delete "/admin/logout", AdminSessionController, :delete
  end

  scope "/admin", ElixirNawalaWeb do
    pipe_through [:browser, :require_admin]

    post "/domains", AdminDomainController, :create
    post "/domains/:id/delete", AdminDomainController, :delete
    live "/dashboard", AdminDashboardLive, :home
    live "/home", AdminDashboardLive, :home
    live "/profile", AdminDashboardLive, :profile
    live "/manager", AdminDashboardLive, :admin_manager
    live "/telegram", AdminDashboardLive, :telegram
    live "/domain/add", AdminDashboardLive, :add_domain
    live "/domain/list", AdminDashboardLive, :list_domain
    live "/domain/status", AdminDashboardLive, :status_domain
    live "/shortlink/create", AdminDashboardLive, :shortlink_create
    live "/shortlink/list", AdminDashboardLive, :shortlink_list
    live "/shortlink/stats", AdminDashboardLive, :shortlink_stats
    live "/shortlink/rotator", AdminDashboardLive, :shortlink_rotator
  end
end
