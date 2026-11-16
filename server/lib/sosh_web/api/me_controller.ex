defmodule SoshWeb.Api.MeController do
  @moduledoc "The signed-in account: everything at once, its character, bag and wallet."
  use SoshWeb, :controller

  import SoshWeb.Api.Json
  alias Sosh.Me

  def show(conn, _), do: ok(conn, Me.everything(conn.assigns.user))

  def character(conn, %{"character" => c}) do
    reply(conn, Me.set_character(conn.assigns.user, c), &%{user: Me.user(&1)})
  end

  def bag(conn, _), do: ok(conn, %{bag: Me.bag(conn.assigns.user)})

  # {deposit: slot} or {withdraw: n} -> {bag, wallet}
  def wallet(conn, params), do: reply(conn, Me.wallet(conn.assigns.user, Me.wallet_op(params)), & &1)
end
