defmodule SoshWeb.ActionChannel do
  @moduledoc """
  Doing things in a universe: `actions:gx,gy`, joined alongside
  `room:gx,gy` with the player's `name` (their bag goes by it).

  The join replies with the universe as `Sosh.Sim.snapshot/1` gives it,
  plus the player's `bag` (`[[item, count] | []]`, `[]` an empty slot) and the `catalog` of
  items and furniture kinds. Updates then arrive as `Sosh.Sim`'s broadcasts.

  Positions are integer block coordinates (Z-up, a block at z spans
  [z, z+1]; see `Sosh.World`): in the world, or with `on` a ship's id, in
  that airship's own frame. Anything aimed at a cell must be within reach
  of where `Sosh.Lobby` predicts the player is. Calls that change the bag
  reply with it as `bag`.
  """
  use Phoenix.Channel

  alias Sosh.{Players, Sim, Universe}

  @reach 7
  @max_chunks_per_request 48
  @max_rot 3

  def join("actions:" <> key, _params, socket) do
    with %{} = account <- socket.assigns[:account] || {:error, %{reason: "signed_out"}},
         name = account.handle,
         {:ok, u} <- SoshWeb.RoomChannel.here(key, name, account.id),
         {:ok, _} <- Sim.ensure(u) do
      reply =
        Sim.snapshot(u)
        |> Map.put(:bag, Players.bag_json(Players.bag(name)))
        |> Map.put(:catalog, Universe.catalog())

      {:ok, reply, socket |> assign(:universe, u) |> assign(:name, name)}
    else
      {:error, %{} = why} -> {:error, why}
      {:error, why} -> {:error, %{reason: to_string(why)}}
    end
  end

  def handle_in("get_chunks", %{"keys" => keys}, socket) when is_list(keys) do
    keys =
      keys
      |> Enum.take(@max_chunks_per_request)
      |> Enum.flat_map(fn
        [cx, cy, cz] when is_integer(cx) and is_integer(cy) and is_integer(cz) -> [{cx, cy, cz}]
        _ -> []
      end)

    {:reply, {:ok, %{chunks: Sim.chunks(u(socket), keys)}}, socket}
  end

  # Dig the block at `position` into the bag. Furniture there breaks apart:
  # some of what it was made of and all it held come back (what doesn't fit
  # the bag is left in a sack). Scaffolding gives back what was put in it.
  def handle_in("dig_action", %{"position" => pos} = params, socket) do
    on = on(params)

    with {:ok, p} <- cell(pos),
         :ok <- within_reach(socket, on, p),
         {:ok, bag} <- Sim.dig(u(socket), user(socket), name(socket), on, p) do
      {:reply, {:ok, %{position: pos, on: on, bag: bag}}, socket}
    end
    |> answer(socket)
  end

  # Place one `item` (or `block_type`, as older clients say) from the bag in
  # the cell `position`: a block, or furniture that packs into a bag, turned
  # `rot` quarter turns. On a ship's cell it becomes part of the ship.
  def handle_in("place_action", %{"position" => pos} = params, socket) do
    item = params["item"] || params["block_type"]
    on = on(params)

    with {:ok, p} <- cell(pos),
         true <- is_binary(item) || {:error, "invalid_item"},
         :ok <- within_reach(socket, on, p),
         {:ok, bag} <- Sim.place(u(socket), name(socket), on, p, item, rot(params)) do
      {:reply, {:ok, %{position: pos, on: on, item: item, bag: bag}}, socket}
    end
    |> answer(socket)
  end

  # Plant a carrot in the air cell `position`, on grass or dirt; grass under
  # it is tilled to dirt. It grows on the universe's world ticks.
  def handle_in("plant_action", %{"position" => pos}, socket) do
    with {:ok, p} <- cell(pos),
         :ok <- within_reach(socket, 0, p),
         :ok <- Sim.plant(u(socket), p) do
      {:reply, {:ok, %{position: pos}}, socket}
    end
    |> answer(socket)
  end

  # Pick the ripe crop in `position` into the bag.
  def handle_in("harvest_action", %{"position" => pos}, socket) do
    with {:ok, p} <- cell(pos),
         :ok <- within_reach(socket, 0, p),
         {:ok, bag} <- Sim.harvest(u(socket), name(socket), p) do
      {:reply, {:ok, %{position: pos, item: "carrot", bag: bag}}, socket}
    end
    |> answer(socket)
  end

  # Pick up the cow `cow`, the furniture `furniture`, or what's at
  # `position` (a pot, or furniture). The universe decides: one thing at a
  # time; heavy furniture waits for a second carrier (`how: "gripped"`);
  # small empty furniture packs into the bag (`how: "pocketed"`).
  def handle_in("pick_up_action", params, socket) do
    with {:ok, what} <- pick_target(params),
         :ok <- reach_target(socket, what),
         {:ok, at} <- Sim.feet(u(socket), user(socket)),
         {:ok, how, bag} <- Sim.pick_up(u(socket), user(socket), name(socket), what, at) do
      reply = %{how: to_string(how)}
      reply = if bag, do: Map.put(reply, :bag, bag), else: reply
      {:reply, {:ok, reply}, socket}
    end
    |> answer(socket)
  end

  # Put what we carry in the cell `position` (furniture with its origin
  # there, turned `rot`). Heavy furniture that never lifted is let go of.
  def handle_in("put_down_action", %{"position" => pos} = params, socket) do
    on = on(params)

    with {:ok, p} <- cell(pos),
         :ok <- within_reach(socket, on, p),
         :ok <- Sim.put_down(u(socket), user(socket), on, p, rot(params)) do
      {:reply, {:ok, %{position: pos, on: on}}, socket}
    end
    |> answer(socket)
  end

  # Lay out the blueprint `kind` with its origin at `position`, turned `rot`.
  def handle_in("build_action", %{"kind" => kind, "position" => pos} = params, socket)
      when is_binary(kind) do
    on = on(params)

    with {:ok, p} <- cell(pos),
         :ok <- within_reach(socket, on, p),
         {:ok, site} <- Sim.build(u(socket), kind, on, p, rot(params)) do
      {:reply, {:ok, %{site: site}}, socket}
    end
    |> answer(socket)
  end

  # Put ingredients from the bag into the blueprint at `position`: as much
  # as it needs of the first missing one we have. `built` is the furniture
  # once the last goes in.
  def handle_in("deposit_action", %{"position" => pos} = params, socket) do
    on = on(params)

    with {:ok, p} <- cell(pos),
         :ok <- within_reach(socket, on, p),
         {:ok, built, bag} <- Sim.deposit(u(socket), name(socket), on, p) do
      {:reply, {:ok, %{built: built, bag: bag}}, socket}
    end
    |> answer(socket)
  end

  # Move bag slot `slot` into furniture `furniture`'s insides.
  def handle_in("stash_action", %{"furniture" => id, "slot" => slot}, socket)
      when is_integer(id) and is_integer(slot) and slot >= 0 do
    with {:ok, at} <- Sim.feet(u(socket), user(socket)),
         {:ok, bag} <- Sim.stash(u(socket), name(socket), at, id, slot) do
      {:reply, {:ok, %{bag: bag}}, socket}
    end
    |> answer(socket)
  end

  # Move furniture `furniture`'s slot `slot` into the bag.
  def handle_in("take_action", %{"furniture" => id, "slot" => slot}, socket)
      when is_integer(id) and is_integer(slot) and slot >= 0 do
    with {:ok, at} <- Sim.feet(u(socket), user(socket)),
         {:ok, bag} <- Sim.take(u(socket), name(socket), at, id, slot) do
      {:reply, {:ok, %{bag: bag}}, socket}
    end
    |> answer(socket)
  end

  # Take the helm of the airship we stand at (`ship` in the reply), or let
  # go of the one we hold (`ship: nil`).
  def handle_in("helm_action", _params, socket) do
    with {:ok, ship} <- Sim.helm(u(socket), user(socket)) do
      {:reply, {:ok, %{ship: ship}}, socket}
    end
    |> answer(socket)
  end

  # At the helm: `helm` [thrust, turn, lift], each -1..1 (ahead, to port,
  # up).
  def handle_in("steer", %{"helm" => [t, r, l]}, socket)
      when is_number(t) and is_number(r) and is_number(l) do
    Sim.steer(u(socket), user(socket), {t, r, l})
    {:noreply, socket}
  end

  # Ask helper `helper` to take the other end of what we're holding.
  def handle_in("call_helper_action", %{"helper" => id}, socket) when is_integer(id) do
    with :ok <- Sim.call_helper(u(socket), user(socket), id) do
      {:reply, :ok, socket}
    end
    |> answer(socket)
  end

  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "bad_request"}}, socket}

  # Whatever they carried is set down when they go, and they leave any helm
  # (a ship crossing into the next universe keeps its pilot).
  def terminate(_reason, socket) do
    if (user_id = socket.assigns[:user_id]) && socket.assigns[:universe] do
      if Sim.running?(u(socket)), do: Sim.release(u(socket), user_id)
    end

    :ok
  end

  # -- helpers

  defp u(socket), do: socket.assigns.universe
  defp user(socket), do: socket.assigns.user_id
  defp name(socket), do: socket.assigns.name

  defp answer({:reply, _, _} = r, _socket), do: r
  defp answer({:error, reason}, socket), do: {:reply, {:error, %{reason: reason}}, socket}

  defp cell([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z),
    do: {:ok, {x, y, z}}

  defp cell(_), do: {:error, "invalid_position_format"}

  defp rot(%{"rot" => r}) when is_integer(r) and r >= 0 and r <= @max_rot, do: r
  defp rot(_), do: 0

  defp pick_target(%{"cow" => id}) when is_integer(id), do: {:ok, {:cow, id}}
  defp pick_target(%{"furniture" => id}) when is_integer(id), do: {:ok, {:furniture, id}}

  defp pick_target(%{"position" => pos} = params) do
    with {:ok, p} <- cell(pos), do: {:ok, {:cell, on(params), p}}
  end

  defp pick_target(_), do: {:error, "invalid_target"}

  # Cows and furniture are reached for by the universe itself.
  defp reach_target(socket, {:cell, on, p}), do: within_reach(socket, on, p)
  defp reach_target(_socket, _), do: :ok

  defp within_reach(socket, on, p), do: Sim.reach(u(socket), user(socket), on, p, @reach)

  # The frame a cell is in: 0 the world, else a ship's id.
  defp on(%{"on" => on}) when is_integer(on) and on >= 0, do: on
  defp on(_), do: 0
end
