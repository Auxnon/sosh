defmodule SoshWeb.RoomChannel do
  @moduledoc """
  A universe's people. Clients (the Petrichor64 client in `client/`) join
  `room:gx,gy`, universe `{gx, gy}` of the grid (`Sosh.Universes`), with
  their name, face and pose. A player is in one universe at a time
  (`Sosh.Players`); joining any other is refused with `reason: "elsewhere"`
  and the `universe` [gx, gy] they're in. The join reply says where they
  stand (`at`): where they left off, aboard the ship they flew in on (`on`
  its id, `local` where on it), or on the home island.

  Server -> client events:
    * `snapshot` `%{players: [player]}` - pushed to a newcomer, everyone present
    * `joined` player - someone arrived
    * `left` `%{user_id}` - someone's channel closed
    * `move` `%{user_id, at, v, to, on, local}` - a change in someone's
      motion: they stand at `at` [x, y, z], moving at `v` [vx, vy] tiles a
      second, and stop at `to` [x, y] if it isn't nil. Clients send it when
      their velocity changes (start, stop, turn, blocked) and once a second
      while moving, and everyone predicts the rest; so does the server, for
      cows (`Sosh.Lobby.position/2`). On an airship `on` is its id and
      `local` [x, y, z] where on it they stand, with `v` and `to` in its
      frame too (`at` is only roughly where that was in the world); else
      `on` is 0 and `local` nil.
    * `face` `%{user_id, face}`, `animation` `%{user_id, animation}`
    * `new_msg` `%{user_id, name, body}` - chat, echoed to the sender too
    * `emote` `%{user_id, emote}` - one of wave, dance, jump, cheer

  where a player is `%{user_id, name, vec, v, to, on, local, face,
  animation}`, `vec` (or, aboard a ship, `local`) being where they are
  predicted to be now.
  """
  use Phoenix.Channel

  alias Sosh.{Lobby, Players, Sim, Universes}

  @max_name 16
  @max_body 280
  # a universe's cells run -48..47; leave room to stand at its edge
  @max_coord 49
  # how far from a ship's middle someone can stand on it
  @max_local 16
  @max_index 63
  # walking is 4.2 tiles a second
  @max_speed 6.0
  @emotes ~w(wave dance jump cheer)

  def join("room:" <> key, params, socket) do
    user_id = socket.assigns.user_id
    name = clean_name(params["name"])

    with {:ok, u} <- here(key, name),
         {:ok, _} <- Sim.ensure(u) do
      me = Players.get(name)
      {{x, y, z}, aboard} = Sim.spawn(u, user_id, me.at)

      {on, local} =
        case aboard do
          {ship, {lx, ly, lz}} -> {ship, [lx, ly, lz]}
          nil -> {0, nil}
        end

      player = %{
        user_id: user_id,
        name: name,
        universe: u,
        at: [x, y, z],
        on: on,
        local: local,
        v: [0, 0],
        to: nil,
        t: Lobby.now(),
        face: clean_index(params["face"]),
        animation: clean_index(params["animation"])
      }

      Lobby.put(user_id, player)
      send(self(), {:after_join, player})
      socket = socket |> assign(:name, name) |> assign(:universe, u)
      {gx, gy} = u

      {:ok,
       %{
         connection_id: socket.assigns.connection_id,
         user_id: user_id,
         universe: [gx, gy],
         at: [x, y, z],
         on: on,
         local: local
       }, socket}
    else
      {:error, %{} = why} -> {:error, why}
      {:error, why} -> {:error, %{reason: to_string(why)}}
    end
  end

  # The universe `key` names, if `name` is in it. Someone whose universe
  # has gone from the grid is back on the plaza.
  @doc false
  def here(key, name) do
    with {:ok, u} <- Universes.parse(key) do
      there = Players.get(name).universe

      there =
        if Universes.exists?(there) do
          there
        else
          Players.move(name, {0, 0})
          {0, 0}
        end

      if there == u do
        {:ok, u}
      else
        {gx, gy} = there
        {:error, %{reason: "elsewhere", universe: [gx, gy]}}
      end
    else
      :error -> {:error, %{reason: "no_such_universe"}}
    end
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
    {on, local} = clean_aboard(payload["on"], payload["local"])

    motion = %{
      at: clean_vec(at),
      v: clean_velocity(payload["v"]),
      to: clean_to(payload["to"]),
      on: on,
      local: local
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

  # They come back where they stood, unless they've moved on to another
  # universe meanwhile.
  def terminate(_reason, socket) do
    user_id = socket.assigns[:user_id]

    if user_id && socket.assigns[:universe] do
      case Lobby.get(user_id) do
        %{} = p -> Players.left(p.name, p.universe, List.to_tuple(Lobby.position(p, Lobby.now())))
        nil -> :ok
      end

      Lobby.delete(user_id)
      SoshWeb.Endpoint.broadcast_from(self(), socket.topic, "left", %{user_id: user_id})
    end

    :ok
  end

  @doc false
  def clean_name(name) when is_binary(name) do
    case name |> String.trim() |> String.slice(0, @max_name) do
      "" -> "guest"
      name -> name
    end
  end

  def clean_name(_), do: "guest"

  defp clean_vec([x, y, z]) when is_number(x) and is_number(y) and is_number(z) do
    [x, y] = Enum.map([x, y], &(&1 |> max(-@max_coord) |> min(@max_coord)))
    [x, y, z |> max(-32) |> min(32)]
  end

  defp clean_vec(_), do: [0, 0, 0]

  defp clean_aboard(on, [x, y, z])
       when is_integer(on) and on > 0 and is_number(x) and is_number(y) and is_number(z) do
    {on, Enum.map([x, y, z], &(&1 |> max(-@max_local) |> min(@max_local)))}
  end

  defp clean_aboard(_, _), do: {0, nil}

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
    {on, at} = Lobby.frame(player, now)

    player
    |> Map.take([:user_id, :name, :v, :to, :face, :animation])
    |> Map.merge(%{
      vec: Lobby.position(player, now),
      on: on,
      local: if(on == 0, do: nil, else: at)
    })
  end

  defp clean_index(i) when is_integer(i) and i >= 0 and i <= @max_index, do: i
  defp clean_index(_), do: 0
end
