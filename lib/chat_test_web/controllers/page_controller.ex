defmodule ChatTestWeb.PageController do
  use ChatTestWeb, :controller

  def home(conn, _params) do
    # The home page is often custom made,
    # so skip the default app layout.
    render(conn, :home, layout: false)
  end

  def index(conn, _params) do
    # render(conn, :index, layout: false)
    html(conn, File.read!("priv/static/index.html"))
  end

  def api_hello(conn, _params) do
    json(conn, %{message: "Hello from Phoenix!"})
  end
end
