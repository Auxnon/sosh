defmodule SoshWeb.RoomChannel do
  @moduledoc """
  The plaza. Clients (the Petrichor64 client in `client/`) join `room:lobby`
  with their name, position, face and pose.

  Server -> client events:
    * `snapshot` `%{players: [player]}` - pushed to a newcomer, everyone present
    * `joined` player - someone arrived
    * `left` `%{user_id}` - someone's channel closed
    * `move` `%{user_id, at, v, to}` - a change in someone's motion: they
      stand at `at` [x, y, z], moving at `v` [vx, vy] tiles a second, and
      stop at `to` [x, y] if it isn't nil. Clients send it when their
      velocity changes (start, stop, turn, blocked) and once a second while
      moving, and everyone predicts the rest; so does the server, for cows
      (`Sosh.Lobby.position/2`).
    * `face` `%{user_id, face}`, `animation` `%{user_id, animation}`
    * `new_msg` `%{user_id, name, body}` - chat, echoed to the sender too
    * `emote` `%{user_id, emote}` - one of wave, dance, jump, cheer

  where a player is `%{user_id, name, vec, v, to, face, animation}`, `vec`
  being where they are predicted to be now.
  """
  use Phoenix.Channel

  alias Sosh.Lobby

  @max_name 16
  @max_body 280
  @max_coord 100
  @max_index 63
  # walking is 4.2 tiles a second
  @max_speed 6.0
  @emotes ~w(wave dance jump cheer)

  def join("room:lobby", params, socket) do
    user_id = socket.assigns.user_id

    player = %{
      user_id: user_id,
      name: clean_name(params["name"]),
      at: clean_vec(params["vec"]),
      v: [0, 0],
      to: nil,
      t: Lobby.now(),
      face: clean_index(params["face"]),
      animation: clean_index(params["animation"])
    }

    Lobby.put(user_id, player)
    send(self(), {:after_join, player})
    socket = assign(socket, :name, player.name)

    {:ok, %{connection_id: socket.assigns.connection_id, user_id: user_id}, socket}
  end

  def join("room:" <> _private_room_id, _params, _socket) do
    {:error, %{reason: "unauthorized"}}
  end

  def handle_info({:after_join, player}, socket) do
    now = Lobby.now()
    push(socket, "snapshot", %{players: Enum.map(Lobby.list(), &public(&1, now))})
    broadcast_from!(socket, "joined", public(player, now))
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

  def handle_in("move", %{"at" => at} = payload, socket) do
    motion = %{
      at: clean_vec(at),
      v: clean_velocity(payload["v"]),
      to: clean_to(payload["to"])
    }

    Lobby.update(socket.assigns.user_id, Map.put(motion, :t, Lobby.now()))
    broadcast_from!(socket, "move", Map.put(motion, :user_id, socket.assigns.user_id))
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

  defp clean_to([x, y]) when is_number(x) and is_number(y) do
    Enum.map([x, y], &(&1 |> max(-@max_coord) |> min(@max_coord)))
  end

  defp clean_to(_), do: nil

  # capped at @max_speed, so a client can't claim to fly (or fling cows)
  defp clean_velocity([vx, vy]) when is_number(vx) and is_number(vy) do
    speed = :math.sqrt(vx * vx + vy * vy)

    if speed > @max_speed,
      do: [vx / speed * @max_speed, vy / speed * @max_speed],
      else: [vx, vy]
  end

  defp clean_velocity(_), do: [0, 0]

  defp public(player, now) do
    player
    |> Map.take([:user_id, :name, :v, :to, :face, :animation])
    |> Map.put(:vec, Lobby.position(player, now))
  end

  defp clean_index(i) when is_integer(i) and i >= 0 and i <= @max_index, do: i
  defp clean_index(_), do: 0
end
