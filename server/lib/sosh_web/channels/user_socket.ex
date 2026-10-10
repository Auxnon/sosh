defmodule SoshWeb.UserSocket do
  use Phoenix.Socket

  ## Channels
  # Existing real-time channel
  channel("room:*", SoshWeb.RoomChannel)
  # New action channel
  channel("actions:*", SoshWeb.ActionChannel)

  # Socket params are passed from the client and can
  # be used to verify and authenticate a user.
  # One user id per connection, shared by every channel on it (the room for
  # presence and chat, actions for world edits).
  def connect(_params, socket, _connect_info) do
    socket =
      socket
      |> assign(:connection_id, UUID.uuid4())
      |> assign(:user_id, UUID.uuid4())

    {:ok, socket}
  end

  # Socket id's are topics that allow you to identify all sockets for a given user:
  def id(_socket), do: nil
end
