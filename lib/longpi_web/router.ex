defmodule LongpiWeb.Router do
  use LongpiWeb, :router

  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LongpiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
  end

  pipeline :api do
    plug :accepts, ["json"]

    plug AshAuthentication.Strategy.ApiKey.Plug,
      resource: Longpi.Accounts.User,
      # if you want to require an api key to be supplied, set `required?` to true
      required?: false

    plug :load_from_bearer
    plug :set_actor, :user
  end

  scope "/", LongpiWeb do
    pipe_through :browser

    ash_authentication_live_session :authenticated_routes do
      # in each liveview, add one of the following at the top of the module:
      #
      # If an authenticated user must be present:
      # on_mount {LongpiWeb.LiveUserAuth, :live_user_required}
      #
      # If an authenticated user *may* be present:
      # on_mount {LongpiWeb.LiveUserAuth, :live_user_optional}
      #
      # If an authenticated user must *not* be present:
      # on_mount {LongpiWeb.LiveUserAuth, :live_no_user}
    end

    get "/rpc/tool-catalog", ConfigController, :tool_catalog
    get "/rpc/config-defaults", ConfigController, :defaults
    post "/rpc/discover-models", ConfigController, :discover_models
    get "/rpc/sessions", ConfigController, :sessions
    post "/rpc/sessions/stop", ConfigController, :stop_session
    get "/rpc/extensions", ConfigController, :extensions
    post "/rpc/extensions/packages", ConfigController, :save_packages
    get "/rpc/version", ConfigController, :version
    post "/rpc/version/upgrade", ConfigController, :upgrade
    post "/rpc/run", AshTypescriptRpcController, :run
    post "/rpc/validate", AshTypescriptRpcController, :validate
    get "/ash-typescript", PageController, :index
  end

  scope "/", LongpiWeb do
    pipe_through :browser

    get "/", PageController, :index
    # Client-side routes: serve the SPA so deep links / refresh resolve.
    get "/c/:id", PageController, :index
    get "/manage", PageController, :index
    get "/manage/:section", PageController, :index
    auth_routes AuthController, Longpi.Accounts.User, path: "/auth"
    sign_out_route AuthController

    # Remove these if you'd like to use your own authentication views
    sign_in_route register_path: "/register",
                  reset_path: "/reset",
                  auth_routes_prefix: "/auth",
                  on_mount: [{LongpiWeb.LiveUserAuth, :live_no_user}],
                  overrides: [
                    LongpiWeb.AuthOverrides,
                    Elixir.AshAuthentication.Phoenix.Overrides.Default
                  ]

    # Remove this if you do not want to use the reset password feature
    reset_route auth_routes_prefix: "/auth",
                overrides: [
                  LongpiWeb.AuthOverrides,
                  Elixir.AshAuthentication.Phoenix.Overrides.Default
                ]

    # Remove this if you do not use the confirmation strategy
    confirm_route Longpi.Accounts.User, :confirm_new_user,
      auth_routes_prefix: "/auth",
      overrides: [LongpiWeb.AuthOverrides, Elixir.AshAuthentication.Phoenix.Overrides.Default]

    # Remove this if you do not use the magic link strategy.
    magic_sign_in_route(Longpi.Accounts.User, :magic_link,
      auth_routes_prefix: "/auth",
      overrides: [LongpiWeb.AuthOverrides, Elixir.AshAuthentication.Phoenix.Overrides.Default]
    )
  end

  # Other scopes may use custom stacks.
  # scope "/api", LongpiWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:longpi, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: LongpiWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  if Application.compile_env(:longpi, :dev_routes) do
    import AshAdmin.Router

    scope "/admin" do
      pipe_through :browser

      ash_admin "/"
    end
  end
end
