defmodule ChatTestWeb.UserSocket do
  use Phoenix.Socket

  ## Channels
  # Existing real-time channel
  channel("room:*", ChatTestWeb.RoomChannel)
  # New action channel
  channel("actions:*", ChatTestWeb.ActionChannel)

  # Socket params are passed from the client and can
  # be used to verify and authenticate a user.
  def connect(_params, socket, _connect_info) do
    socket = assign(socket, :connection_id, UUID.uuid4())
    {:ok, socket}
  end

  # Socket id's are topics that allow you to identify all sockets for a given user:
  def id(_socket), do: nil
end
