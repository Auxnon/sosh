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

  # {move: [from, to]}, {split: [slot, n]} or {drop: slot} -> {bag}
  def arrange(conn, params), do: reply(conn, Sosh.Me.bag_op(conn.assigns.user, Me.bag_op_of(params)), &%{bag: &1})

  # {deposit: slot} or {withdraw: n} -> {bag, wallet}
  def wallet(conn, params), do: reply(conn, Me.wallet(conn.assigns.user, Me.wallet_op(params)), & &1)
end
