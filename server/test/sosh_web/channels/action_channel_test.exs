defmodule SoshWeb.ActionChannelTest do
  # Shares the universes, Sosh.Lobby and Sosh.Players with every other
  # test: not async.
  use SoshWeb.ChannelCase

  alias Sosh.{Lobby, Players, Sim, World}

  @plaza {0, 0}

  setup %{socket: socket} do
    {:ok, _, actions} = enter(socket, "builder")
    %{actions: actions}
  end

  # Join universe (0, 0) as `name`, standing at `at`: being in the room is
  # what gives reach.
  defp enter(socket, name, at \\ [0.5, 0.5, 0]) do
    {:ok, %{user_id: id}, _} =
      subscribe_and_join(socket, SoshWeb.RoomChannel, "room:0,0", %{"name" => name})

    Lobby.update(id, %{at: at})
    subscribe_and_join(socket, SoshWeb.ActionChannel, "actions:0,0", %{"name" => name})
  end

  defp count(bag, item) do
    for([^item, n] <- bag, do: n) |> Enum.sum()
  end

  defp stand(actions, at), do: Lobby.update(actions.assigns.user_id, %{at: at})

  # Stand on `ship` at `local` in its frame.
  defp aboard(actions, ship, local),
    do: Lobby.update(actions.assigns.user_id, %{on: ship.id, local: local, v: [0, 0]})

  # Where to stand to steer the standard ship: astern of its helm.
  @at_helm [-4.0, 0.0, 0.0]

  test "rejects a socket that isn't signed in" do
    socket = Phoenix.Socket.assign(%Phoenix.Socket{}, :user_id, "x")

    assert {:error, %{reason: "signed_out"}} =
             SoshWeb.ActionChannel.join("actions:0,0", %{}, socket)
  end

  test "joining replies with the universe, the bag and the catalog", %{socket: socket} do
    {:ok, reply, _} =
      subscribe_and_join(socket, SoshWeb.ActionChannel, "actions:0,0", %{"name" => "builder"})

    assert %{universe: [0, 0], kind: "sea", open: [true, false, false, false]} = reply
    assert count(reply.bag, "wood") == 24
    assert [%{name: "Porter"}, %{name: "Hob"}] = reply.helpers
    assert [%{pilot: nil, blocks: [[_, _, _, _] | _]}] = reply.ships
    assert %{kinds: kinds, items: _, bag_slots: 16} = reply.catalog

    assert %{size: [2, 1, 1], carriers: 2, recipe: [["wood", 6], ["stone", 2]]} =
             Enum.find(kinds, &(&1.name == "dresser"))

    assert {:error, %{reason: "elsewhere", universe: [0, 0]}} =
             subscribe_and_join(socket, SoshWeb.ActionChannel, "actions:1,0", %{
               "name" => "builder"
             })
  end

  test "get_chunks returns the plaza, run-length encoded", %{actions: actions} do
    ref = push(actions, "get_chunks", %{"keys" => [[0, 0, -1], [0, 0, 0], ["bad"], [9, 9, 9]]})
    assert_reply(ref, :ok, %{chunks: [floor, sky]})

    assert floor.key == [0, 0, -1]
    assert Enum.sum(Enum.take_every(tl(floor.rle), 2)) == 4096
    # the chunk above the floor is all air
    assert sky.rle == [0, 4096]
  end

  test "digging puts the block in the bag and tells everyone", %{actions: actions} do
    assert Sim.block(@plaza, {2, 2, -1}) == World.block_ids()["grass"]

    ref = push(actions, "dig_action", %{"position" => [2, 2, -1]})
    assert_reply(ref, :ok, %{bag: bag})
    assert count(bag, "grass") == 1
    assert_broadcast("block_changed", %{position: [2, 2, -1], block: 0, block_type: "air"})
    assert Sim.block(@plaza, {2, 2, -1}) == 0

    ref = push(actions, "dig_action", %{"position" => [2, 2, -1]})
    assert_reply(ref, :error, %{reason: "nothing_there"})
  end

  test "building spends from the bag", %{actions: actions} do
    ref = push(actions, "place_action", %{"position" => [1, 1, 0], "item" => "wood"})
    assert_reply(ref, :ok, %{bag: bag})
    assert count(bag, "wood") == 23
    assert_broadcast("block_changed", %{position: [1, 1, 0], block_type: "wood"})

    ref = push(actions, "place_action", %{"position" => [1, 1, 0], "block_type" => "stone"})
    assert_reply(ref, :error, %{reason: "occupied"})

    ref = push(actions, "place_action", %{"position" => [1, 2, 0], "item" => "lava"})
    assert_reply(ref, :error, %{reason: "cannot_place"})

    # two pots to start with
    for x <- [2, 3] do
      ref = push(actions, "place_action", %{"position" => [x, 1, 0], "item" => "pot"})
      assert_reply(ref, :ok, _)
    end

    ref = push(actions, "place_action", %{"position" => [4, 1, 0], "item" => "pot"})
    assert_reply(ref, :error, %{reason: "none_left"})
  end

  test "edits out of reach are refused", %{actions: actions} do
    ref = push(actions, "dig_action", %{"position" => [15, 0, -1]})
    assert_reply(ref, :error, %{reason: "out_of_reach"})

    ref = push(actions, "dig_action", %{"position" => [1.5, 0, -1]})
    assert_reply(ref, :error, %{reason: "invalid_position_format"})
  end

  test "edits and furniture survive a save and a restart", %{actions: actions, socket: socket} do
    ref = push(actions, "place_action", %{"position" => [0, 1, 0], "item" => "stone"})
    assert_reply(ref, :ok, _)
    ref = push(actions, "build_action", %{"kind" => "chest", "position" => [2, 1, 0]})
    assert_reply(ref, :ok, _)
    ref = push(actions, "deposit_action", %{"position" => [2, 1, 0]})
    assert_reply(ref, :ok, %{built: chest})

    :ok = Sim.save(@plaza)
    assert Sosh.Repo.aggregate(Sosh.Chunk, :count) == 1
    Sim.stop_all()

    {:ok, reply, _} = enter(socket, "builder")
    assert Sim.block(@plaza, {0, 1, 0}) == World.block_ids()["stone"]
    assert [%{id: ^chest, kind: "chest", origin: [2, 1, 0]}] = reply.furniture
    # and the bag kept what was spent
    assert count(reply.bag, "wood") == 20
  end

  describe "farming" do
    test "plant tills grass, grows on world ticks and harvests into the bag", %{actions: actions} do
      ref = push(actions, "plant_action", %{"position" => [2, 3, 0]})
      assert_reply(ref, :ok, %{position: [2, 3, 0]})
      assert_broadcast("crop", %{position: [2, 3, 0], stage: 0})
      assert_broadcast("block_changed", %{position: [2, 3, -1], block_type: "dirt"})
      assert Sim.block(@plaza, {2, 3, -1}) == World.block_ids()["dirt"]

      ref = push(actions, "harvest_action", %{"position" => [2, 3, 0]})
      assert_reply(ref, :error, %{reason: "not_ripe"})

      # stage_ms is 1s in test: three stages later it's ripe
      :ok = Sim.tick(@plaza, System.os_time(:millisecond) + 3_500)
      assert_broadcast("crop", %{position: [2, 3, 0], stage: 3})

      ref = push(actions, "harvest_action", %{"position" => [2, 3, 0]})
      assert_reply(ref, :ok, %{item: "carrot", bag: bag})
      assert count(bag, "carrot") == 1
      assert_broadcast("crop", %{position: [2, 3, 0], stage: nil})

      ref = push(actions, "harvest_action", %{"position" => [2, 3, 0]})
      assert_reply(ref, :error, %{reason: "nothing_growing"})
    end

    test "planting needs soil and an empty cell", %{actions: actions} do
      ref = push(actions, "plant_action", %{"position" => [2, 2, 0]})
      assert_reply(ref, :ok, _)
      ref = push(actions, "plant_action", %{"position" => [2, 2, 0]})
      assert_reply(ref, :error, %{reason: "occupied"})
      ref = push(actions, "plant_action", %{"position" => [2, 2, 1]})
      assert_reply(ref, :error, %{reason: "needs_soil"})
      # a block can't go where a crop grows
      ref = push(actions, "place_action", %{"position" => [2, 2, 0], "item" => "wood"})
      assert_reply(ref, :error, %{reason: "occupied"})
    end

    test "digging the soil uproots the crop", %{actions: actions} do
      ref = push(actions, "plant_action", %{"position" => [3, 2, 0]})
      assert_reply(ref, :ok, _)
      ref = push(actions, "dig_action", %{"position" => [3, 2, -1]})
      assert_reply(ref, :ok, _)
      assert_broadcast("crop", %{position: [3, 2, 0], stage: nil})
      assert Sim.crop(@plaza, {3, 2, 0}) == nil
    end

    test "the plaza's crops from before universes come back, grown" do
      Sosh.Repo.insert!(%Sosh.Crop{x: 4, y: 4, z: 0, planted_ms: 0})
      :ok = Sim.reset(@plaza)
      assert Sim.crop(@plaza, {4, 4, 0}) == Sim.ripe()
    end

    test "an empty universe sleeps and catches up when someone comes back", %{actions: actions} do
      ref = push(actions, "plant_action", %{"position" => [2, 3, 0]})
      assert_reply(ref, :ok, _)
      :ok = Sim.save(@plaza)
      # restarted: it's asleep since the save, and nothing grows asleep
      Sim.stop_all()
      {:ok, _} = Sim.ensure(@plaza)
      assert Sim.crop(@plaza, {2, 3, 0}) == 0
      :ok = Sim.ambient(@plaza, System.os_time(:millisecond) + 5_000)
      assert Sim.crop(@plaza, {2, 3, 0}) == 0
      # someone's back three world seconds later: it catches up at once
      :ok = Sim.tick(@plaza, System.os_time(:millisecond) + 3_000)
      assert Sim.crop(@plaza, {2, 3, 0}) == 3
    end
  end

  describe "cows" do
    test "join replies with cows; a player pushes a cow", %{socket: socket} do
      :ok = Sim.reset(@plaza, cows: 1)
      {:ok, reply, _} = enter(socket, "builder")
      assert %{cows: [[id, x, y, _z, _h]]} = reply

      # stand just west of it: the cow is shoved east and moos
      now = System.os_time(:millisecond)
      :ok = Sim.tick(@plaza, now)
      [user | _] = Lobby.list()
      Lobby.update(user.user_id, %{at: [x - 0.3, y, 0]})
      :ok = Sim.tick(@plaza, now + 100)
      assert_broadcast("moo", %{ids: [^id]})
      # (subscribed twice, and the first tick announces the cow where it
      # stood: look past those)
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "cows",
                       payload: %{rows: [[^id, x2, _, _, _]]}
                     }
                     when x2 > x + 0.4
    end
  end

  describe "carrying" do
    test "a pot is picked up, carried and put down again", %{actions: actions} do
      pot = World.block_ids()["pot"]
      ref = push(actions, "place_action", %{"position" => [1, 2, 0], "item" => "pot"})
      assert_reply(ref, :ok, _)

      ref = push(actions, "pick_up_action", %{"position" => [1, 2, 0]})
      assert_reply(ref, :ok, %{how: "block"})
      assert_broadcast("carry", %{block: ^pot, cow: nil, furniture: nil, user_id: user})
      assert_broadcast("block_changed", %{position: [1, 2, 0], block: 0})
      assert %{held: [%{user_id: ^user, block: ^pot}]} = Sim.snapshot(@plaza)

      # one thing at a time
      ref = push(actions, "place_action", %{"position" => [2, 1, 0], "item" => "pot"})
      assert_reply(ref, :ok, _)
      ref = push(actions, "pick_up_action", %{"position" => [2, 1, 0]})
      assert_reply(ref, :error, %{reason: "hands_full"})

      ref = push(actions, "put_down_action", %{"position" => [2, 1, 0]})
      assert_reply(ref, :error, %{reason: "occupied"})
      ref = push(actions, "put_down_action", %{"position" => [1, 3, 0]})
      assert_reply(ref, :ok, _)
      assert_broadcast("carry", %{block: nil, cow: nil})
      assert_broadcast("block_changed", %{position: [1, 3, 0], block: ^pot, block_type: "pot"})

      ref = push(actions, "put_down_action", %{"position" => [1, 4, 0]})
      assert_reply(ref, :error, %{reason: "hands_empty"})
    end

    test "only some blocks can be carried", %{actions: actions} do
      assert %{carryable: [7]} = Sim.snapshot(@plaza)
      ref = push(actions, "pick_up_action", %{"position" => [2, 2, -1]})
      assert_reply(ref, :error, %{reason: "cannot_carry"})
    end

    test "a cow is carried overhead and set down", %{socket: socket} do
      :ok = Sim.reset(@plaza, cows: 1)
      {:ok, %{cows: [[id, x, y, _, _]]}, actions} = enter(socket, "builder")

      stand(actions, [x - 1, y, 0])
      ref = push(actions, "pick_up_action", %{"cow" => id})
      assert_reply(ref, :ok, %{how: "cow"})
      assert_broadcast("carry", %{cow: ^id})
      ref = push(actions, "pick_up_action", %{"cow" => id})
      assert_reply(ref, :error, %{reason: "hands_full"})

      # carried over to the path ring, and set down there
      stand(actions, [-4.5, 3.5, 0])
      ref = push(actions, "put_down_action", %{"position" => [-4, 4, 0]})
      assert_reply(ref, :ok, _)
      assert %{held: []} = Sim.snapshot(@plaza)
    end

    test "leaving puts the pot back where they stood", %{actions: actions} do
      ref = push(actions, "place_action", %{"position" => [0, 2, 0], "item" => "pot"})
      assert_reply(ref, :ok, _)
      ref = push(actions, "pick_up_action", %{"position" => [0, 2, 0]})
      assert_reply(ref, :ok, _)

      Process.unlink(actions.channel_pid)
      close(actions)
      # they stood at (0.5, 0.5, 0): cell (1, 1, 0)
      assert_broadcast("block_changed", %{position: [1, 1, 0], block: 7})
      assert %{held: []} = Sim.snapshot(@plaza)
    end
  end

  describe "furniture" do
    test "a blueprint is built from what's put into it", %{actions: actions} do
      ref =
        push(actions, "build_action", %{"kind" => "dresser", "position" => [2, 2, 0], "rot" => 1})

      assert_reply(ref, :ok, %{site: site})

      assert_broadcast("site", %{
        id: ^site,
        kind: "dresser",
        have: [],
        need: [["wood", 6], ["stone", 2]]
      })

      assert_broadcast("block_changed", %{position: [2, 3, 0], block_type: "scaffold"})

      # all the wood, then the stone
      ref = push(actions, "deposit_action", %{"position" => [2, 3, 0]})
      assert_reply(ref, :ok, %{built: nil, bag: bag})
      assert count(bag, "wood") == 18
      assert_broadcast("site", %{id: ^site, have: [["wood", 6]]})
      ref = push(actions, "deposit_action", %{"position" => [2, 2, 0]})
      assert_reply(ref, :ok, %{built: id, bag: bag})
      assert count(bag, "stone") == 10
      assert_broadcast("site_gone", %{id: ^site})
      assert_broadcast("furniture", %{id: ^id, kind: "dresser", rot: 1, slots: slots})
      assert length(slots) == 16

      ref = push(actions, "deposit_action", %{"position" => [4, 4, 0]})
      assert_reply(ref, :error, %{reason: "no_blueprint_there"})
      ref = push(actions, "build_action", %{"kind" => "throne", "position" => [4, 4, 0]})
      assert_reply(ref, :error, %{reason: "no_such_blueprint"})
    end

    test "a chest holds things; breaking it gives everything back", %{actions: actions} do
      ref = push(actions, "build_action", %{"kind" => "chest", "position" => [2, 2, 0]})
      assert_reply(ref, :ok, _)
      ref = push(actions, "deposit_action", %{"position" => [2, 2, 0]})
      assert_reply(ref, :ok, %{built: chest, bag: bag})

      slot = Enum.find_index(bag, &match?(["stone", _], &1))
      ref = push(actions, "stash_action", %{"furniture" => chest, "slot" => slot})
      assert_reply(ref, :ok, %{bag: bag})
      assert count(bag, "stone") == 0
      assert_broadcast("furniture", %{id: ^chest, slots: [["stone", 12] | _]})

      ref = push(actions, "take_action", %{"furniture" => chest, "slot" => 0})
      assert_reply(ref, :ok, %{bag: bag})
      assert count(bag, "stone") == 12
      slot = Enum.find_index(bag, &match?(["stone", _], &1))
      ref = push(actions, "stash_action", %{"furniture" => chest, "slot" => slot})
      assert_reply(ref, :ok, _)

      # broken: half its wood back, and the stone that was in it
      ref = push(actions, "dig_action", %{"position" => [2, 2, 0]})
      assert_reply(ref, :ok, %{bag: bag})
      assert count(bag, "wood") == 22
      assert count(bag, "stone") == 12
      assert_broadcast("furniture_gone", %{id: ^chest})
      assert Players.bag("builder") |> Enum.find(&match?({"stone", _}, &1))
    end

    test "heavy furniture takes two; a helper can be one", %{actions: actions} do
      ref = push(actions, "build_action", %{"kind" => "dresser", "position" => [2, -2, 0]})
      assert_reply(ref, :ok, _)

      for _ <- 1..2 do
        ref = push(actions, "deposit_action", %{"position" => [2, -2, 0]})
        assert_reply(ref, :ok, %{built: built})
        if built, do: send(self(), {:built, built})
      end

      assert_received {:built, dresser}

      ref = push(actions, "pick_up_action", %{"furniture" => dresser})
      assert_reply(ref, :ok, %{how: "gripped"})
      assert_broadcast("carry", %{furniture: ^dresser})

      # a second player lifts the other end
      {:ok, other} = connect(SoshWeb.UserSocket, %{})
      {:ok, _, theirs} = enter(other, "lifter", [3.5, -0.5, 0])
      ref = push(theirs, "pick_up_action", %{"position" => [3, -2, 0]})
      assert_reply(ref, :ok, %{how: "lifted"})
      assert_broadcast("furniture", %{id: ^dresser, lifted: true, carriers: [_, _]})
      assert Sim.block(@plaza, {2, -2, 0}) == 0

      ref = push(theirs, "put_down_action", %{"position" => [2, -4, 0], "rot" => 0})
      assert_reply(ref, :ok, _)
      assert Sim.block(@plaza, {3, -4, 0}) == World.block_ids()["furniture"]

      # this time a helper takes the other end
      stand(actions, [2.5, -2.5, 0])
      ref = push(actions, "pick_up_action", %{"furniture" => dresser})
      assert_reply(ref, :ok, %{how: "gripped"})
      %{helpers: [%{id: porter} | _]} = Sim.snapshot(@plaza)
      ref = push(actions, "call_helper_action", %{"helper" => porter})
      assert_reply(ref, :ok)

      now = System.os_time(:millisecond)

      Enum.reduce_while(1..100, now, fn _, t ->
        :ok = Sim.tick(@plaza, t)
        f = Enum.find(Sim.snapshot(@plaza).furniture, &(&1.id == dresser))
        if f.lifted, do: {:halt, t}, else: {:cont, t + 100}
      end)

      assert_broadcast("furniture", %{id: ^dresser, lifted: true, helpers: [^porter]})
    end

    test "small empty furniture packs into the bag and back out", %{actions: actions} do
      ref = push(actions, "build_action", %{"kind" => "stool", "position" => [2, 2, 0]})
      assert_reply(ref, :ok, _)
      ref = push(actions, "deposit_action", %{"position" => [2, 2, 0]})
      assert_reply(ref, :ok, %{built: stool})
      ref = push(actions, "pick_up_action", %{"furniture" => stool})
      assert_reply(ref, :ok, %{how: "pocketed", bag: bag})
      assert count(bag, "stool") == 1

      ref =
        push(actions, "place_action", %{"position" => [3, 3, 0], "item" => "stool", "rot" => 2})

      assert_reply(ref, :ok, %{bag: bag})
      assert count(bag, "stool") == 0
      assert_broadcast("furniture", %{kind: "stool", origin: [3, 3, 0], rot: 2})
    end
  end

  describe "airships" do
    test "take the helm, fly, let go", %{actions: actions} do
      %{ships: [ship]} = Sim.snapshot(@plaza)
      ref = push(actions, "helm_action", %{})
      assert_reply(ref, :error, %{reason: "no_helm_here"})

      aboard(actions, ship, @at_helm)
      ref = push(actions, "helm_action", %{})
      id = ship.id
      assert_reply(ref, :ok, %{ship: ^id})
      user = actions.assigns.user_id
      assert_broadcast("ship", %{id: ^id, pilot: ^user})

      push(actions, "steer", %{"helm" => [0, 0, 1]})
      :sys.get_state(actions.channel_pid)
      now = System.os_time(:millisecond)
      for n <- 0..20, do: Sim.tick(@plaza, now + n * 100)
      assert_broadcast("ships", %{rows: [[^id, _, _, _, _, _, _, _, _] | _]})
      assert [%{z: z}] = Sim.snapshot(@plaza).ships
      assert z > ship.z + 1

      ref = push(actions, "helm_action", %{})
      assert_reply(ref, :ok, %{ship: nil})
      assert_broadcast("ship", %{id: ^id, pilot: nil})
    end

    test "building on deck", %{actions: actions} do
      %{ships: [ship]} = Sim.snapshot(@plaza)
      id = ship.id

      ref =
        push(actions, "place_action", %{"position" => [0, 0, 0], "on" => id, "item" => "stone"})

      assert_reply(ref, :error, %{reason: "out_of_reach"})

      aboard(actions, ship, [-1.0, 0.0, 0.0])

      ref =
        push(actions, "place_action", %{"position" => [0, 0, 0], "on" => id, "item" => "stone"})

      assert_reply(ref, :ok, %{on: ^id, bag: bag})
      assert count(bag, "stone") == 11
      stone = World.block_ids()["stone"]
      assert_broadcast("ship_block", %{ship: ^id, position: [0, 0, 0], block: ^stone})
      assert Sim.block(@plaza, id, {0, 0, 0}) == stone

      ref = push(actions, "dig_action", %{"position" => [0, 0, 0], "on" => id})
      assert_reply(ref, :ok, %{bag: bag})
      assert count(bag, "stone") == 12
    end

    test "flying off the east edge carries the ship and all aboard into the next universe",
         %{actions: actions} do
      %{ships: [ship]} = Sim.snapshot(@plaza)
      aboard(actions, ship, @at_helm)
      ref = push(actions, "helm_action", %{})
      assert_reply(ref, :ok, _)
      user = actions.assigns.user_id

      # up above the islands, then turn east
      push(actions, "steer", %{"helm" => [0, 0, 1]})
      :sys.get_state(actions.channel_pid)
      now = System.os_time(:millisecond)
      for n <- 0..60, do: Sim.tick(@plaza, now + n * 100)

      t =
        Enum.reduce_while(1..200, now + 6_200, fn _, t ->
          [%{heading: h}] = Sim.snapshot(@plaza).ships

          if abs(h) < 0.05 do
            {:halt, t}
          else
            push(actions, "steer", %{"helm" => [0, if(h > 0, do: -0.3, else: 0.3), 0]})
            :sys.get_state(actions.channel_pid)
            :ok = Sim.tick(@plaza, t)
            {:cont, t + 100}
          end
        end)

      push(actions, "steer", %{"helm" => [1, 0, 0]})
      :sys.get_state(actions.channel_pid)

      Enum.reduce_while(1..400, t, fn _, t ->
        :ok = Sim.tick(@plaza, t)
        if Sim.snapshot(@plaza).ships == [], do: {:halt, t}, else: {:cont, t + 100}
      end)

      assert_broadcast("travel", %{users: [^user], to: [1, 0]})
      assert Players.get("builder").universe == {1, 0}
      # the ship is universe (1, 0)'s now, still theirs to steer, at its
      # west edge
      %{ships: ships} = Sim.snapshot({1, 0})
      assert %{id: there, x: x} = Enum.find(ships, &(&1.pilot == user))
      assert x < -47
      # and they're at its helm when they join it
      {{sx, _, _}, {^there, {-4.0, +0.0, +0.0}}} = Sim.spawn({1, 0}, user, nil)
      assert sx < -45
    end
  end
end
