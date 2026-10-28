defmodule SoshWeb.Api.FriendController do
  @moduledoc "Friends and requests: see `Sosh.Friends`."
  use SoshWeb, :controller

  import SoshWeb.Api.Json
  alias Sosh.Friends

  def index(conn, _), do: ok(conn, Friends.list(conn.assigns.user))

  def create(conn, %{"handle" => h}),
    do: reply(conn, Friends.request(conn.assigns.user, h), &%{status: &1})

  def accept(conn, %{"handle" => h}), do: reply(conn, Friends.accept(conn.assigns.user, h))

  def delete(conn, %{"handle" => h}), do: reply(conn, Friends.remove(conn.assigns.user, h))
end
