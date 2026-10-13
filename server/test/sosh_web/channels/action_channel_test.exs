defmodule SoshWeb.ActionChannelTest do
  # Shares Sosh.World and Sosh.Lobby with every other test: not async.
  use SoshWeb.ChannelCase

  alias Sosh.{Lobby, Sim, World}

  setup %{socket: socket} do
    Enum.each(Lobby.list(), &Lobby.delete(&1.user_id))
    :ok = Sim.reset(cows: 0)
    # Standing at the plaza centre: a user in the room is what gives reach.
    {:ok, _, _} =
      subscribe_and_join(socket, SoshWeb.RoomChannel, "room:lobby", %{
        "name" => "builder",
        "vec" => [0.5, 0.5, 0]
      })

    {:ok, _, actions} = subscribe_and_join(socket, SoshWeb.ActionChannel, "actions:lobby")
    %{actions: actions}
  end

  test "rejects join without user_id" do
    socket = Phoenix.Socket.assign(%Phoenix.Socket{}, :user_id, nil)

    assert {:error, %{reason: "not_authenticated"}} =
             SoshWeb.ActionChannel.join("actions:lobby", %{}, socket)
  end

  test "get_chunks returns the plaza, run-length encoded", %{actions: actions} do
    ref = push(actions, "get_chunks", %{"keys" => [[0, 0, -1], [0, 0, 0], ["bad"]]})
    assert_reply(ref, :ok, %{chunks: [floor, sky]})

    assert floor.key == [0, 0, -1]
    assert Enum.sum(Enum.take_every(tl(floor.rle), 2)) == 4096
    # the chunk above the floor is all air
    assert sky.rle == [0, 4096]
  end

  test "dig removes a block and tells everyone", %{actions: actions} do
    assert World.block(2, 2, -1) == World.block_ids()["grass"]

    ref = push(actions, "dig_action", %{"position" => [2, 2, -1]})
    assert_reply(ref, :ok, %{block_type: "air"})
    assert_broadcast("block_changed", %{position: [2, 2, -1], block: 0})
    assert World.block(2, 2, -1) == 0

    ref = push(actions, "dig_action", %{"position" => [2, 2, -1]})
    assert_reply(ref, :error, %{reason: "nothing_there"})
  end

  test "place fills air, refuses occupied cells and bad types", %{actions: actions} do
    ref = push(actions, "place_action", %{"position" => [1, 1, 0], "block_type" => "wood"})
    assert_reply(ref, :ok, %{block_type: "wood"})
    assert_broadcast("block_changed", %{position: [1, 1, 0], block_type: "wood"})

    ref = push(actions, "place_action", %{"position" => [1, 1, 0], "block_type" => "stone"})
    assert_reply(ref, :error, %{reason: "occupied"})

    ref = push(actions, "place_action", %{"position" => [1, 2, 0], "block_type" => "lava"})
    assert_reply(ref, :error, %{reason: "invalid_block_type"})
  end

  test "edits out of reach are refused", %{actions: actions} do
    ref = push(actions, "dig_action", %{"position" => [15, 0, -1]})
    assert_reply(ref, :error, %{reason: "out_of_reach"})

    ref = push(actions, "dig_action", %{"position" => [1.5, 0, -1]})
    assert_reply(ref, :error, %{reason: "invalid_position_format"})
  end

  test "edits survive a save and reload from Postgres", %{actions: actions} do
    ref = push(actions, "place_action", %{"position" => [0, 1, 0], "block_type" => "stone"})
    assert_reply(ref, :ok, _)

    assert {:ok, 1} = World.save()
    assert {:ok, 0} = World.save()
    # forget everything in memory: the block must come back from the database
    World.reset()
    assert World.block(0, 1, 0) == World.block_ids()["stone"]
    assert Sosh.Repo.aggregate(Sosh.Chunk, :count) == 1
  end

  describe "farming" do
    test "plant tills grass, grows on the clock and harvests when ripe", %{actions: actions} do
      ref = push(actions, "plant_action", %{"position" => [2, 3, 0]})
      assert_reply(ref, :ok, %{position: [2, 3, 0]})
      assert_broadcast("crop", %{position: [2, 3, 0], stage: 0})
      assert_broadcast("block_changed", %{position: [2, 3, -1], block_type: "dirt"})
      assert World.block(2, 3, -1) == World.block_ids()["dirt"]
      assert Sosh.Repo.aggregate(Sosh.Crop, :count) == 1

      ref = push(actions, "harvest_action", %{"position" => [2, 3, 0]})
      assert_reply(ref, :error, %{reason: "not_ripe"})

      # stage_ms is 1s in test: three stages later it's ripe
      :ok = Sim.tick(System.os_time(:millisecond) + 3_500)
      assert_broadcast("crop", %{position: [2, 3, 0], stage: 3})

      ref = push(actions, "harvest_action", %{"position" => [2, 3, 0]})
      assert_reply(ref, :ok, %{item: "carrot"})
      assert_broadcast("crop", %{position: [2, 3, 0], stage: nil})
      assert Sosh.Repo.aggregate(Sosh.Crop, :count) == 0

      ref = push(actions, "harvest_action", %{"position" => [2, 3, 0]})
      assert_reply(ref, :error, %{reason: "nothing_growing"})
    end

    test "planting needs soil and an empty cell", %{actions: actions} do
      ref = push(actions, "plant_action", %{"position" => [2, 2, 0]})
      assert_reply(ref, :ok, _)
      ref = push(actions, "plant_action", %{"position" => [2, 2, 0]})
      assert_reply(ref, :error, %{reason: "occupied"})
      # nothing to grow in: the cell above is air over the crop
      ref = push(actions, "plant_action", %{"position" => [2, 2, 1]})
      assert_reply(ref, :error, %{reason: "needs_soil"})
      # a block can't go where a crop grows
      ref = push(actions, "place_action", %{"position" => [2, 2, 0], "block_type" => "wood"})
      assert_reply(ref, :error, %{reason: "occupied"})
    end

    test "digging the soil uproots the crop", %{actions: actions} do
      ref = push(actions, "plant_action", %{"position" => [3, 2, 0]})
      assert_reply(ref, :ok, _)
      ref = push(actions, "dig_action", %{"position" => [3, 2, -1]})
      assert_reply(ref, :ok, _)
      assert_broadcast("crop", %{position: [3, 2, 0], stage: nil})
      assert Sim.crop({3, 2, 0}) == nil
    end

    test "crops come back from Postgres, grown by the time passed" do
      Sosh.Repo.insert!(%Sosh.Crop{x: 4, y: 4, z: 0, planted_ms: 0})
      :ok = Sim.reset(cows: 0)
      assert Sim.crop({4, 4, 0}) == Sim.ripe()
    end
  end

  describe "cows" do
    test "join replies with cows and crops; a player pushes a cow", %{socket: socket} do
      :ok = Sim.reset(cows: 1)
      {:ok, reply, _} = subscribe_and_join(socket, SoshWeb.ActionChannel, "actions:lobby")
      assert %{crops: [], cows: [[id, x, y, _z, _h]]} = reply

      # stand just west of it: the cow is shoved east and moos
      now = System.os_time(:millisecond)
      :ok = Sim.tick(now)
      [user | _] = Lobby.list()
      Lobby.update(user.user_id, %{at: [x - 0.3, y, 0]})
      :ok = Sim.tick(now + 100)
      assert_broadcast("moo", %{ids: [^id]})
      # (subscribed twice, setup's join and this one, and the first tick
      # announces the cow where it stood: look past those)
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "cows",
                       payload: %{cows: [[^id, x2, _, _, _]]}
                     }
                     when x2 > x + 0.4
    end
  end

  describe "carrying" do
    test "a pot is picked up, carried and put down again", %{actions: actions} do
      pot = World.block_ids()["pot"]
      ref = push(actions, "place_action", %{"position" => [1, 2, 0], "block_type" => "pot"})
      assert_reply(ref, :ok, _)

      ref = push(actions, "pick_up_action", %{"position" => [1, 2, 0]})
      assert_reply(ref, :ok, %{block: ^pot, cow: nil})
      assert_broadcast("carry", %{block: ^pot, cow: nil, user_id: user})
      assert_broadcast("block_changed", %{position: [1, 2, 0], block: 0})
      assert World.block(1, 2, 0) == 0
      assert %{held: [%{user_id: ^user, block: ^pot}]} = Sim.snapshot()

      # one thing at a time
      ref = push(actions, "place_action", %{"position" => [2, 1, 0], "block_type" => "pot"})
      assert_reply(ref, :ok, _)
      ref = push(actions, "pick_up_action", %{"position" => [2, 1, 0]})
      assert_reply(ref, :error, %{reason: "hands_full"})

      ref = push(actions, "put_down_action", %{"position" => [2, 1, 0]})
      assert_reply(ref, :error, %{reason: "occupied"})
      ref = push(actions, "put_down_action", %{"position" => [1, 3, 0]})
      assert_reply(ref, :ok, %{block: ^pot})
      assert_broadcast("carry", %{block: nil, cow: nil})
      assert_broadcast("block_changed", %{position: [1, 3, 0], block: ^pot, block_type: "pot"})
      assert World.block(1, 3, 0) == pot

      ref = push(actions, "put_down_action", %{"position" => [1, 4, 0]})
      assert_reply(ref, :error, %{reason: "hands_empty"})
    end

    test "the universe says what can be carried", %{actions: actions} do
      assert %{carryable: [7]} = Sim.snapshot()
      ref = push(actions, "pick_up_action", %{"position" => [2, 2, -1]})
      assert_reply(ref, :error, %{reason: "cannot_carry"})
      assert World.block(2, 2, -1) == World.block_ids()["grass"]
    end

    test "a cow is carried overhead and set down", %{socket: socket} do
      :ok = Sim.reset(cows: 1)

      {:ok, %{cows: [[id, x, y, _, _]]}, actions} =
        subscribe_and_join(socket, SoshWeb.ActionChannel, "actions:lobby")

      [user | _] = Lobby.list()
      Lobby.update(user.user_id, %{at: [x - 1, y, 0]})
      ref = push(actions, "pick_up_action", %{"cow" => id})
      assert_reply(ref, :ok, %{cow: ^id})
      assert_broadcast("carry", %{cow: ^id})
      ref = push(actions, "pick_up_action", %{"cow" => id})
      assert_reply(ref, :error, %{reason: "hands_full"})

      cell = [round(x - 2), round(y), 0]
      ref = push(actions, "put_down_action", %{"position" => cell})
      assert_reply(ref, :ok, %{cow: ^id})
      assert %{held: []} = Sim.snapshot()
    end

    test "leaving puts the pot back where they stood", %{actions: actions} do
      ref = push(actions, "place_action", %{"position" => [0, 2, 0], "block_type" => "pot"})
      assert_reply(ref, :ok, _)
      ref = push(actions, "pick_up_action", %{"position" => [0, 2, 0]})
      assert_reply(ref, :ok, _)

      Process.unlink(actions.channel_pid)
      close(actions)
      # they stood at (0.5, 0.5, 0): cell (1, 1, 0)
      assert_broadcast("block_changed", %{position: [1, 1, 0], block: 7})
      assert %{held: []} = Sim.snapshot()
    end
  end
end
