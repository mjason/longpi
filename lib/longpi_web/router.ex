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

  # Auth gates — no-ops until auth is enabled (Longpi.Auth.enabled?).
  pipeline :require_auth_page do
    plug LongpiWeb.Plugs.RequireAuth, mode: :page
  end

  pipeline :require_auth_api do
    plug LongpiWeb.Plugs.RequireAuth, mode: :api
  end

  # The embed view is meant to be iframed by other apps (e.g. dala's terminal
  # pane), so drop the SAMEORIGIN frame guard for it. This is a self-hosted
  # tool; when auth is enabled the page itself still requires sign-in.
  pipeline :embeddable do
    plug :allow_embedding
  end

  # Phoenix 1.8's put_secure_browser_headers guards with CSP
  # `frame-ancestors 'self'` (ports count as different origins, so a host app
  # on another port can't iframe us). Relax just that directive here.
  defp allow_embedding(conn, _opts) do
    conn
    |> Plug.Conn.delete_resp_header("x-frame-options")
    |> Plug.Conn.put_resp_header("content-security-policy", "base-uri 'self'; frame-ancestors *;")
  end

  # Data plane: everything the SPA fetches. 401s (never redirects) when auth
  # is enabled and there is no session.
  scope "/", LongpiWeb do
    pipe_through [:browser, :require_auth_api]

    get "/rpc/tool-catalog", ConfigController, :tool_catalog
    get "/rpc/config-defaults", ConfigController, :defaults
    post "/rpc/discover-models", ConfigController, :discover_models
    get "/rpc/sessions", ConfigController, :sessions
    post "/rpc/sessions/stop", ConfigController, :stop_session
    get "/rpc/extensions", ConfigController, :extensions
    post "/rpc/extensions/packages", ConfigController, :save_packages
    get "/rpc/extensions/secrets", ConfigController, :extension_secrets
    post "/rpc/extensions/secrets", ConfigController, :save_extension_secret
    post "/rpc/extensions/secrets/delete", ConfigController, :delete_extension_secret
    get "/rpc/version", ConfigController, :version
    post "/rpc/version/upgrade", ConfigController, :upgrade
    post "/rpc/run", AshTypescriptRpcController, :run
    post "/rpc/validate", AshTypescriptRpcController, :validate
    get "/ash-typescript", PageController, :index
  end

  # The SPA pages — sign-in required when auth is enabled.
  scope "/", LongpiWeb do
    pipe_through [:browser, :require_auth_page]

    get "/", PageController, :index
    # Client-side routes: serve the SPA so deep links / refresh resolve.
    get "/c/:id", PageController, :index
    get "/manage", PageController, :index
    get "/manage/:section", PageController, :index
  end

  # Embed mode: the same SPA, iframable by a host app (e.g. dala's terminal
  # pane). The React side renders a chrome-less conversation for `?cwd=`;
  # `?theme=` forces light/dark.
  scope "/", LongpiWeb do
    pipe_through [:browser, :require_auth_page, :embeddable]

    get "/embed", PageController, :index
  end

  # Sign-in / sign-out. No self-registration, password reset, confirmation, or
  # magic link — accounts are seeded at boot from LONGPI_USERS
  # (Longpi.Accounts.Seeder), mirroring dala's model.
  scope "/", LongpiWeb do
    pipe_through :browser

    auth_routes AuthController, Longpi.Accounts.User, path: "/auth"
    sign_out_route AuthController

    sign_in_route auth_routes_prefix: "/auth",
                  on_mount: [{LongpiWeb.LiveUserAuth, :live_no_user}],
                  overrides: [
                    LongpiWeb.AuthOverrides,
                    Elixir.AshAuthentication.Phoenix.Overrides.Default
                  ]
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
      pipe_through [:browser, :require_auth_page]

      live_dashboard "/dashboard", metrics: LongpiWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  if Application.compile_env(:longpi, :dev_routes) do
    import AshAdmin.Router

    scope "/admin" do
      pipe_through [:browser, :require_auth_page]

      ash_admin "/"
    end
  end
end
