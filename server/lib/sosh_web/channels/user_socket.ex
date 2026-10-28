defmodule SoshWeb.UserSocket do
  @moduledoc """
  One connection. It's signed in by a session token (`Sosh.Accounts`):
  the `token` socket param, or, for the Android app's embedded world view,
  `sosh-token/<token>` in its user agent (a web view can't add socket
  params the game didn't write). Without one the connection can only use
  `auth:lobby`, to sign in or up and get a token to reconnect with.

  Every connection also gets a fresh `user_id`: who it is in a universe
  (`Sosh.Sim`, `Sosh.Lobby`), since the same account could connect twice.
  """
  use Phoenix.Socket

  channel "auth:*", SoshWeb.AuthChannel
  channel "user:*", SoshWeb.UserChannel
  channel "server:*", SoshWeb.ServerChannel
  channel "dm:*", SoshWeb.DmChannel
  channel "room:*", SoshWeb.RoomChannel
  channel "actions:*", SoshWeb.ActionChannel

  @impl true
  def connect(params, socket, connect_info) do
    token = params["token"] || ua_token(connect_info[:user_agent])
    user = token && Sosh.Accounts.session_user(token)

    socket =
      socket
      |> assign(:connection_id, UUID.uuid4())
      |> assign(:user_id, UUID.uuid4())
      |> assign(:account, user)
      |> assign(:token, user && token)
      |> assign(:caller, caller(connect_info[:peer_data]))

    {:ok, socket}
  end

  defp ua_token(ua) when is_binary(ua) do
    case Regex.run(~r/sosh-token\/([A-Za-z0-9_-]{20,})/, ua) do
      [_, t] -> t
      _ -> nil
    end
  end

  defp ua_token(_), do: nil

  defp caller(%{address: a}), do: a |> :inet.ntoa() |> to_string()
  defp caller(_), do: "socket"

  # Signed-in sockets are `account:<id>`, so signing out everywhere
  # (`SoshWeb.Endpoint.broadcast("account:<id>", "disconnect", %{})`) closes them.
  @impl true
  def id(%{assigns: %{account: %{id: id}}}), do: "account:#{id}"
  def id(_), do: nil

  @doc "The signed-in account on a channel's socket, or nil."
  def account(socket), do: socket.assigns[:account]
end
