defmodule ChatTestWeb.UserSocket do
  use Phoenix.Socket

  channel("room:*", ChatTestWeb.RoomChannel)

  def connect(_params, socket, _connect_info) do
    socket = assign(socket, :connection_id, UUID.uuid4())
    {:ok, socket}
  end

  def id(_socket), do: nil
end
