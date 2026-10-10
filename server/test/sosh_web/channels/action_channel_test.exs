defmodule SoshWeb.ActionChannelTest do
  # Shares Sosh.World and Sosh.Lobby with every other test: not async.
  use SoshWeb.ChannelCase

  alias Sosh.{Lobby, World}

  setup %{socket: socket} do
    Enum.each(Lobby.list(), &Lobby.delete(&1.user_id))
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
    assert_reply ref, :ok, %{chunks: [floor, sky]}

    assert floor.key == [0, 0, -1]
    assert Enum.sum(Enum.take_every(tl(floor.rle), 2)) == 4096
    # the chunk above the floor is all air
    assert sky.rle == [0, 4096]
  end

  test "dig removes a block and tells everyone", %{actions: actions} do
    assert World.block(2, 2, -1) == World.block_ids()["grass"]

    ref = push(actions, "dig_action", %{"position" => [2, 2, -1]})
    assert_reply ref, :ok, %{block_type: "air"}
    assert_broadcast "block_changed", %{position: [2, 2, -1], block: 0}
    assert World.block(2, 2, -1) == 0

    ref = push(actions, "dig_action", %{"position" => [2, 2, -1]})
    assert_reply ref, :error, %{reason: "nothing_there"}
  end

  test "place fills air, refuses occupied cells and bad types", %{actions: actions} do
    ref = push(actions, "place_action", %{"position" => [1, 1, 0], "block_type" => "wood"})
    assert_reply ref, :ok, %{block_type: "wood"}
    assert_broadcast "block_changed", %{position: [1, 1, 0], block_type: "wood"}

    ref = push(actions, "place_action", %{"position" => [1, 1, 0], "block_type" => "stone"})
    assert_reply ref, :error, %{reason: "occupied"}

    ref = push(actions, "place_action", %{"position" => [1, 2, 0], "block_type" => "lava"})
    assert_reply ref, :error, %{reason: "invalid_block_type"}
  end

  test "edits out of reach are refused", %{actions: actions} do
    ref = push(actions, "dig_action", %{"position" => [15, 0, -1]})
    assert_reply ref, :error, %{reason: "out_of_reach"}

    ref = push(actions, "dig_action", %{"position" => [1.5, 0, -1]})
    assert_reply ref, :error, %{reason: "invalid_position_format"}
  end

  test "edits survive a save and reload from Postgres", %{actions: actions} do
    ref = push(actions, "place_action", %{"position" => [0, 1, 0], "block_type" => "stone"})
    assert_reply ref, :ok, _

    assert {:ok, 1} = World.save()
    assert {:ok, 0} = World.save()
    # forget everything in memory: the block must come back from the database
    World.reset()
    assert World.block(0, 1, 0) == World.block_ids()["stone"]
    assert Sosh.Repo.aggregate(Sosh.Chunk, :count) == 1
  end
end
