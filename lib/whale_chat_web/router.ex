defmodule WhaleChatWeb.Router do
  use WhaleChatWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {WhaleChatWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug WhaleChatWeb.Plugs.ChatIdentity
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :chat_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug WhaleChatWeb.Plugs.ChatIdentity
  end

  pipeline :mapsdb_api do
    plug :accepts, ["json"]
    plug :fetch_session
  end

  scope "/", WhaleChatWeb do
    pipe_through :browser

    get "/", LegacyController, :home
    get "/index.php", LegacyController, :home
    get "/index.html", LegacyController, :home
    get "/info", InfoController, :entry
    get "/info/index.html", InfoController, :entry
    get "/stats", StatsController, :index
    get "/stats/index.php", StatsController, :index
    get "/nav", PageController, :home
    live "/chat", ChatLive
    get "/online", OnlineController, :index
    get "/logs", LogsController, :index
    get "/logs/", LogsController, :index
    get "/logs/index.php", LogsController, :index
    get "/logs/short", LogsController, :short
    get "/logs/short/", LogsController, :short
    get "/logs/short/index.php", LogsController, :short
    get "/logs/current", LogsController, :current
    get "/logs/current/", LogsController, :current
    get "/logs/current/index.php", LogsController, :current
    get "/stats/login.php", StatsLoginController, :show
    get "/mapsdb", MapsDbController, :index
    get "/mapsdb/index.php", MapsDbController, :index
    get "/mapsdb/login.php", MapsDbLoginController, :show
  end

  scope "/stats", WhaleChatWeb do
    pipe_through :chat_api

    get "/chat.php", ChatApiController, :index
    post "/chat.php", ChatApiController, :create
    get "/online_summary.php", OnlineSummaryController, :index
    get "/online.php", OnlineApiController, :index
    get "/fetch_page.php", StatsApiController, :fetch_page
    get "/cumulative_fragment.php", StatsApiController, :cumulative_fragment
    get "/logs_fragment.php", StatsApiController, :logs_fragment
    get "/current_log_fragment.php", StatsApiController, :current_log_fragment
  end

  scope "/mapsdb", WhaleChatWeb do
    pipe_through :mapsdb_api

    get "/api.php", MapsDbApiController, :handle
    post "/api.php", MapsDbApiController, :handle
  end

  scope "/", WhaleChatWeb do
    pipe_through :browser

    match :*, "/*path", LegacyController, :passthrough
  end

  # Other scopes may use custom stacks.
  # scope "/api", WhaleChatWeb do
  #   pipe_through :api
  # end
end
