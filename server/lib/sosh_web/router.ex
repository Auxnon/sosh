defmodule SoshWeb.Router do
  use SoshWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SoshWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :signed_in do
    plug SoshWeb.Api.AuthPlug
  end

  # The account API (JSON). Signing in answers a token; everything under
  # :signed_in wants it as `Authorization: Bearer <token>`.
  scope "/api", SoshWeb.Api do
    pipe_through :api

    post "/auth/register", AuthController, :register
    post "/auth/confirm", AuthController, :confirm
    post "/auth/resend", AuthController, :resend
    post "/auth/login", AuthController, :login
    post "/auth/forgot", AuthController, :forgot
    post "/auth/reset", AuthController, :reset
  end

  scope "/api", SoshWeb.Api do
    pipe_through [:api, :signed_in]

    delete "/auth/session", AuthController, :logout
    post "/auth/password", AuthController, :password

    get "/me", MeController, :show
    put "/me/character", MeController, :character
    get "/me/bag", MeController, :bag

    get "/friends", FriendController, :index
    post "/friends", FriendController, :create
    post "/friends/:handle/accept", FriendController, :accept
    delete "/friends/:handle", FriendController, :delete

    get "/servers", ServerController, :index
    patch "/servers/:id", ServerController, :update
    get "/servers/:id/members", ServerController, :members
    post "/servers/:id/join", ServerController, :join
    post "/servers/:id/leave", ServerController, :leave
    post "/servers/:id/invite", ServerController, :invite
    post "/servers/:id/members/:handle/:action", ServerController, :member

    get "/servers/:id/messages", ChatController, :server_index
    post "/servers/:id/messages", ChatController, :server_create
    get "/dms", ChatController, :dms
    get "/dms/:handle/messages", ChatController, :dm_index
    post "/dms/:handle/messages", ChatController, :dm_create
    post "/messages/:id/claim", ChatController, :claim
    post "/messages/:id/cancel", ChatController, :cancel
    delete "/messages/:id", ChatController, :delete
  end

  scope "/api", SoshWeb do
    pipe_through :api
    get "/hello", PageController, :api_hello
  end

  scope "/", SoshWeb do
    pipe_through :browser
    # get "/assets/*path", :not_found
    get "/*path", PageController, :index
  end

  # scope "/", SoshWeb do
  #   pipe_through :browser
  #
  #   get "/", PageController, :home
  # end

  # Other scopes may use custom stacks.
  # scope "/api", SoshWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:sosh, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SoshWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
