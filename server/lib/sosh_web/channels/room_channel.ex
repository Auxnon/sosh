defmodule SoshWeb.RoomChannel do
  @moduledoc """
  The plaza. Clients (the Petrichor64 client in `client/`) join `room:lobby`
  with their name, position, face and pose.

  Server -> client events:
    * `snapshot` `%{players: [player]}` - pushed to a newcomer, everyone present
    * `joined` player - someone arrived
    * `left` `%{user_id}` - someone's channel closed
    * `move` `%{user_id, vec}` - walk target. Clients may add `at`, where
      they actually stand; the server keeps it (Sosh.Lobby) so players push
      cows (Sosh.Sim), and doesn't forward it.
    * `face` `%{user_id, face}`, `animation` `%{user_id, animation}`
    * `new_msg` `%{user_id, name, body}` - chat, echoed to the sender too
    * `emote` `%{user_id, emote}` - one of wave, dance, jump, cheer

  where a player is `%{user_id, name, vec, face, animation}`.
  """
  use Phoenix.Channel

  alias Sosh.Lobby

  @max_name 16
  @max_body 280
  @max_coord 100
  @max_index 63
  @emotes ~w(wave dance jump cheer)

  def join("room:lobby", params, socket) do
    user_id = socket.assigns.user_id

    vec = clean_vec(params["vec"])

    player = %{
      user_id: user_id,
      name: clean_name(params["name"]),
      vec: vec,
      face: clean_index(params["face"]),
      animation: clean_index(params["animation"])
    }

    Lobby.put(user_id, Map.put(player, :at, vec))
    send(self(), {:after_join, player})
    socket = assign(socket, :name, player.name)

    {:ok, %{connection_id: socket.assigns.connection_id, user_id: user_id}, socket}
  end

  def join("room:" <> _private_room_id, _params, _socket) do
    {:error, %{reason: "unauthorized"}}
  end

  def handle_info({:after_join, player}, socket) do
    push(socket, "snapshot", %{players: Lobby.list()})
    broadcast_from!(socket, "joined", player)
    {:noreply, socket}
  end

  def handle_in("new_msg", %{"body" => body}, socket) when is_binary(body) do
    case body |> String.trim() |> String.slice(0, @max_body) do
      "" ->
        {:noreply, socket}

      body ->
        broadcast!(socket, "new_msg", %{
          body: body,
          user_id: socket.assigns.user_id,
          name: socket.assigns.name
        })

        {:noreply, socket}
    end
  end

  def handle_in("move", %{"vec" => vec} = payload, socket) do
    vec = clean_vec(vec)
    at = if payload["at"], do: clean_vec(payload["at"]), else: vec
    Lobby.update(socket.assigns.user_id, %{vec: vec, at: at})
    broadcast_from!(socket, "move", %{vec: vec, user_id: socket.assigns.user_id})
    {:noreply, socket}
  end

  def handle_in("face", %{"face" => face}, socket) do
    face = clean_index(face)
    Lobby.update(socket.assigns.user_id, %{face: face})
    broadcast_from!(socket, "face", %{face: face, user_id: socket.assigns.user_id})
    {:noreply, socket}
  end

  def handle_in("animation", %{"animation" => animation}, socket) do
    animation = clean_index(animation)
    Lobby.update(socket.assigns.user_id, %{animation: animation})

    broadcast_from!(socket, "animation", %{
      animation: animation,
      user_id: socket.assigns.user_id
    })

    {:noreply, socket}
  end

  def handle_in("emote", %{"emote" => emote}, socket) when emote in @emotes do
    broadcast_from!(socket, "emote", %{emote: emote, user_id: socket.assigns.user_id})
    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  def terminate(_reason, socket) do
    if user_id = socket.assigns[:user_id] do
      Lobby.delete(user_id)
      SoshWeb.Endpoint.broadcast_from(self(), socket.topic, "left", %{user_id: user_id})
    end

    :ok
  end

  defp clean_name(name) when is_binary(name) do
    case name |> String.trim() |> String.slice(0, @max_name) do
      "" -> "guest"
      name -> name
    end
  end

  defp clean_name(_), do: "guest"

  defp clean_vec([x, y, z]) when is_number(x) and is_number(y) and is_number(z) do
    Enum.map([x, y, z], &(&1 |> max(-@max_coord) |> min(@max_coord)))
  end

  defp clean_vec(_), do: [0, 0, 0]

  defp clean_index(i) when is_integer(i) and i >= 0 and i <= @max_index, do: i
  defp clean_index(_), do: 0
end
