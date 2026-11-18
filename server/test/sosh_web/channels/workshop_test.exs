defmodule SoshWeb.WorkshopTest do
  # Crafting in a universe and out of one, stations, breaking, shearing and
  # being stuck under something too heavy. Shares the universes, Sosh.Lobby
  # and Sosh.Players with every other test: not async.
  use SoshWeb.ChannelCase

  import Ecto.Query, only: [from: 2]

  alias Phoenix.Socket.Broadcast
  alias Sosh.{Accounts, Lobby, Players, Repo, Sim, Universe, UniverseRecord, World}

  @plaza {0, 0}
  @bench [-3, 0, 0]

  # a saw cut straight across the plank, and a slanted one that wastes some
  @cut (for i <- 0..10, do: [0.5, i / 10])
  @poor (for i <- 0..10, do: [0.1 + 0.08 * i, 0.4 + 0.02 * i])

  setup %{socket: socket} do
    {_, room, actions} = enter(socket, "maker")
    %{actions: actions, room: room}
  end

  # Join universe (0, 0) as `name`, standing at `at`: `{actions_reply, room, actions}`.
  defp enter(socket, name, at \\ [0.5, 0.5, 0]) do
    {:ok, %{user_id: id}, room} =
      subscribe_and_join(socket, SoshWeb.RoomChannel, "room:0,0", %{"name" => name})

    Lobby.update(id, %{at: at})

    {:ok, reply, actions} =
      subscribe_and_join(socket, SoshWeb.ActionChannel, "actions:0,0", %{"name" => name})

    {reply, room, actions}
  end

  defp count(bag, item), do: for([^item, n] <- bag, do: n) |> Enum.sum()

  defp give(name, item, n),
    do: {:ok, _} = Players.update_bag(name, &Universe.bag_give(&1, item, n))

  defp give(name, stuff), do: Enum.each(stuff, fn {item, n} -> give(name, to_string(item), n) end)

  defp stand(actions, at), do: Lobby.update(actions.assigns.user_id, %{at: at})

  defp now, do: System.os_time(:millisecond)

  # A bench set down at `pos`, and a tick for the universe to notice who's near it.
  defp put_bench(actions, pos \\ @bench) do
    give("maker", "bench", 1)
    ref = push(actions, "place_action", %{"position" => pos, "item" => "bench"})
    assert_reply(ref, :ok, _)
    :ok = Sim.tick(@plaza, now())
  end

  defp dresser_parts, do: give("maker", plank: 4, post: 2, stone: 2)

  defp leave_room(room) do
    Process.unlink(room.channel_pid)
    ref = Process.monitor(room.channel_pid)
    leave(room)
    assert_receive {:DOWN, ^ref, _, _, _}
  end

  defp watch_user(handle), do: SoshWeb.Endpoint.subscribe("user:#{Accounts.get_by_handle(handle).id}")

  defp assert_stations(list) do
    assert_receive %Broadcast{topic: "user:" <> _, event: "stations", payload: %{stations: ^list}}
  end

  describe "stations" do
    test "a station step goes by the server's record, never the client's say", %{actions: actions} do
      give("maker", "plank", 3)
      ref = push(actions, "craft_action", %{"step" => "post", "stroke" => @cut})
      assert_reply(ref, :error, %{reason: "no_station_near"})

      # claiming to be at one changes nothing
      ref =
        push(actions, "craft_action", %{
          "step" => "post",
          "stroke" => @cut,
          "stations" => ["bench"],
          "station" => "bench"
        })

      assert_reply(ref, :error, %{reason: "no_station_near"})
      assert Players.stations("maker") == []

      watch_user("maker")
      put_bench(actions)
      assert_stations(["bench"])
      assert Players.stations("maker") == ["bench"]
      # the player's own business, not the universe's
      refute_received %Broadcast{topic: "actions:0,0", event: "stations"}

      ref = push(actions, "craft_action", %{"step" => "post", "stroke" => @cut})
      assert_reply(ref, :ok, %{step: "post", item: "post", n: 2, how: "bag", furniture: nil, bag: bag})
      assert count(bag, "post") == 2
      assert count(bag, "plank") == 2

      # a poor cut wastes some, and no stroke at all is the least, never none
      ref = push(actions, "craft_action", %{"step" => "post", "stroke" => @poor})
      assert_reply(ref, :ok, %{n: 1, score: score})
      assert score < 0.5
      ref = push(actions, "craft_action", %{"step" => "post"})
      assert_reply(ref, :ok, %{n: 1, score: +0.0, bag: bag})
      assert count(bag, "post") == 4
      assert count(bag, "plank") == 0

      ref = push(actions, "craft_action", %{"step" => "post", "stroke" => @cut})
      assert_reply(ref, :error, %{reason: "missing_ingredients"})
      ref = push(actions, "craft_action", %{"step" => "post", "stroke" => "zigzag"})
      assert_reply(ref, :error, %{reason: "bad_stroke"})
      ref = push(actions, "craft_action", %{"step" => "throne"})
      assert_reply(ref, :error, %{reason: "no_such_step"})
      ref = push(actions, "craft_action", %{"step" => 7})
      assert_reply(ref, :error, %{reason: "bad_request"})

      # walked away from it
      give("maker", "plank", 1)
      stand(actions, [30.5, 0.5, 0])
      :ok = Sim.tick(@plaza, now() + 100)
      assert_stations([])
      assert Players.stations("maker") == []
      ref = push(actions, "craft_action", %{"step" => "post", "stroke" => @cut})
      assert_reply(ref, :error, %{reason: "no_station_near"})
    end

    test "recorded again on coming back, whether or not the universe noticed them go",
         %{socket: socket, actions: actions, room: room} do
      watch_user("maker")
      put_bench(actions)
      assert_stations(["bench"])

      # gone and back before the universe ticked: it never saw them leave
      leave_room(room)
      assert Players.stations("maker") == []
      assert_stations([])
      {_, room, _} = enter(socket, "maker")
      :ok = Sim.tick(@plaza, now() + 100)
      assert Players.stations("maker") == ["bench"]
      assert_stations(["bench"])

      # gone for a tick: it forgets them, then finds them near it again
      leave_room(room)
      :ok = Sim.tick(@plaza, now() + 200)
      assert Players.stations("maker") == []
      {_, _, _} = enter(socket, "maker")
      :ok = Sim.tick(@plaza, now() + 300)
      assert Players.stations("maker") == ["bench"]
      refute_received %Broadcast{topic: "actions:0,0", event: "stations"}
    end

    test "a universe they've left doesn't overwrite the next one's", %{actions: actions} do
      put_bench(actions)
      # flown on into the next universe (as an airship takes them) before
      # this one's lobby knows: that one has them near a loom
      Players.move("maker", {1, 0})
      assert {:ok, ["loom"]} = Players.set_stations("maker", ["loom"], {1, 0})
      stand(actions, [30.5, 0.5, 0])
      :ok = Sim.tick(@plaza, now() + 100)
      assert Players.stations("maker") == ["loom"]
      assert {:error, :elsewhere} = Players.set_stations("maker", ["bench"], @plaza)
    end
  end

  describe "hand steps" do
    test "made in a world without a station", %{actions: actions} do
      ref = push(actions, "craft_action", %{"step" => "veneer"})
      assert_reply(ref, :ok, %{item: "veneer", n: 1, score: 1.0, how: "bag", bag: bag})
      assert count(bag, "veneer") == 1
      assert count(bag, "wood") == 20
    end

    test "made outside any world, over the user channel" do
      user = account("hander")
      {:ok, socket} = connect(SoshWeb.UserSocket, %{"token" => Accounts.new_session(user)})

      {:ok, _, ch} =
        Phoenix.ChannelTest.subscribe_and_join(socket, SoshWeb.UserChannel, "user:#{user.id}", %{})

      ref = push(ch, "craft", %{"step" => "veneer"})
      assert_reply(ref, :ok, %{step: "veneer", item: "veneer", n: 1, how: "bag", furniture: nil, bag: bag})
      assert count(bag, "veneer") == 1
      assert_push("bag", %{bag: ^bag})
      assert Players.bag_json(Players.bag("hander")) == bag

      ref = push(ch, "craft", %{"step" => "plank"})
      assert_reply(ref, :error, %{reason: "no_station_near"})
      ref = push(ch, "craft", %{"step" => "nope"})
      assert_reply(ref, :error, %{reason: "no_such_step"})
      ref = push(ch, "craft", %{"step" => 5})
      assert_reply(ref, :error, %{reason: "no_such_step"})
      ref = push(ch, "craft", %{})
      assert_reply(ref, :error, %{reason: "bad_request"})

      # in reach of a bench in a world (as a universe records it), its steps
      # can be done from here too, with no stroke; heavy furniture waits to
      # be finished in a world
      Players.set_stations("hander", ["bench"])
      give("hander", plank: 2, post: 4, cloth: 3)
      ref = push(ch, "craft", %{"step" => "bed"})
      assert_reply(ref, :error, %{reason: "place_or_carry"})
      assert count(Players.bag_json(Players.bag("hander")), "cloth") == 3
      ref = push(ch, "craft", %{"step" => "post"})
      assert_reply(ref, :ok, %{item: "post", n: 1})

      Players.put_bag("hander", List.duplicate(nil, 16))
      ref = push(ch, "craft", %{"step" => "veneer"})
      assert_reply(ref, :error, %{reason: "missing_ingredients"})
    end
  end

  describe "heavy furniture" do
    test "is built where aimed, within reach, or not at all", %{actions: actions} do
      put_bench(actions)
      dresser_parts()

      ref = push(actions, "craft_action", %{"step" => "dresser"})
      assert_reply(ref, :error, %{reason: "place_or_carry"})
      ref = push(actions, "craft_action", %{"step" => "dresser", "how" => "toss"})
      assert_reply(ref, :error, %{reason: "bad_finish"})
      ref = push(actions, "craft_action", %{"step" => "dresser", "how" => "place"})
      assert_reply(ref, :error, %{reason: "bad_finish"})

      ref =
        push(actions, "craft_action", %{"step" => "dresser", "how" => "place", "position" => [20, 0, 0]})

      assert_reply(ref, :error, %{reason: "out_of_reach"})
      assert count(Players.bag_json(Players.bag("maker")), "plank") == 4

      ref =
        push(actions, "craft_action", %{
          "step" => "dresser",
          "how" => "place",
          "position" => [2, 2, 0],
          "rot" => 1
        })

      assert_reply(ref, :ok, %{item: "dresser", how: "place", furniture: id, bag: bag})
      assert count(bag, "plank") == 0
      assert count(bag, "dresser") == 0
      assert_broadcast("furniture", %{id: ^id, kind: "dresser", origin: [2, 2, 0], rot: 1})
      assert Sim.block(@plaza, {2, 2, 0}) == World.block_ids()["furniture"]

      # nothing's taken for one that can't go there
      dresser_parts()

      ref =
        push(actions, "craft_action", %{"step" => "dresser", "how" => "place", "position" => [2, 2, 0]})

      assert_reply(ref, :error, %{reason: "occupied"})
      assert count(Players.bag_json(Players.bag("maker")), "plank") == 4
    end

    test "carried, it pins its maker until a second carrier takes hold",
         %{actions: actions, room: room} do
      put_bench(actions)
      dresser_parts()
      user = actions.assigns.user_id

      ref = push(actions, "craft_action", %{"step" => "dresser", "how" => "carry"})
      assert_reply(ref, :ok, %{how: "carry", furniture: id})
      assert_broadcast("carry", %{user_id: ^user, furniture: ^id, pinned: true})
      assert_broadcast("encumbered", %{user_id: ^user, pinned: true, on: 0, at: [x, y, _] = at})
      assert_broadcast("move", %{user_id: ^user, at: ^at, v: [0, 0], to: nil, on: 0})
      assert %{held: [%{furniture: ^id, pinned: true}]} = Sim.snapshot(@plaza)

      # one thing at a time
      dresser_parts()
      ref = push(actions, "craft_action", %{"step" => "dresser", "how" => "carry"})
      assert_reply(ref, :error, %{reason: "hands_full"})

      # walking is refused, and nobody hears of it
      push(room, "move", %{"at" => [3.0, 3.0, 0], "v" => [1.0, 0]})
      :sys.get_state(room.channel_pid)
      assert %{at: ^at, v: [0, 0], pinned: true} = Lobby.get(user)
      refute_broadcast("move", %{user_id: ^user})

      # a second carrier takes the other end: both are free
      {:ok, other} = connect(SoshWeb.UserSocket, %{})
      {_, _, theirs} = enter(other, "lifter", [x + 1, y, 0])
      ref = push(theirs, "pick_up_action", %{"furniture" => id})
      assert_reply(ref, :ok, %{how: "lifted"})
      assert_broadcast("encumbered", %{user_id: ^user, pinned: false, on: nil, at: nil})
      refute Lobby.get(user).pinned

      push(room, "move", %{"at" => [1.0, 1.0, 0], "v" => [1.0, 0]})
      :sys.get_state(room.channel_pid)
      assert %{at: [1.0, 1.0, 0], v: [1.0, 0]} = Lobby.get(user)
      assert_broadcast("move", %{user_id: ^user, at: [1.0, 1.0, 0]})
    end
  end

  describe "breaking" do
    test "what's held, what's in reach and empty, nothing else", %{actions: actions} do
      put_bench(actions)
      user = actions.assigns.user_id
      ref = push(actions, "break_action", %{})
      assert_reply(ref, :error, %{reason: "nothing_to_break"})

      # stuck under a dresser: break it in their arms, and they're free
      dresser_parts()
      ref = push(actions, "craft_action", %{"step" => "dresser", "how" => "carry"})
      assert_reply(ref, :ok, %{furniture: dresser})
      wood = count(Players.bag_json(Players.bag("maker")), "wood")

      ref = push(actions, "break_action", %{})
      # three quarters of 5 wood and 2 stone, rounded down
      assert_reply(ref, :ok, %{returned: [["wood", 3], ["stone", 1]], sack: nil, bag: bag})
      assert count(bag, "wood") == wood + 3
      assert_broadcast("furniture_gone", %{id: ^dresser})
      assert_broadcast("encumbered", %{user_id: ^user, pinned: false})
      assert %{held: []} = Sim.snapshot(@plaza)

      # a chest close by, empty
      give("maker", "plank", 4)

      ref =
        push(actions, "craft_action", %{"step" => "chest", "how" => "place", "position" => [2, 2, 0]})

      assert_reply(ref, :ok, %{furniture: chest})
      stand(actions, [20.5, 0.5, 0])
      ref = push(actions, "break_action", %{"furniture" => chest})
      assert_reply(ref, :error, %{reason: "out_of_reach"})
      stand(actions, [0.5, 0.5, 0])
      ref = push(actions, "break_action", %{"furniture" => chest})
      assert_reply(ref, :ok, %{returned: [["wood", 3]], sack: nil})
      assert_broadcast("furniture_gone", %{id: ^chest})
      assert Sim.block(@plaza, {2, 2, 0}) == 0

      ref = push(actions, "break_action", %{"furniture" => chest})
      assert_reply(ref, :error, %{reason: "no_such_furniture"})
      ref = push(actions, "break_action", %{"furniture" => "chest"})
      assert_reply(ref, :error, %{reason: "invalid_target"})
    end

    test "a blueprint from before recipes still loads and breaks for all put in it",
         %{socket: socket} do
      :ok = Sim.save(@plaza)
      saved = Jason.decode!(Sosh.Universes.get(@plaza).state)
      site = %{"id" => 900, "kind" => "dresser", "on" => 0, "origin" => [2, -2, 0], "rot" => 0, "have" => [["wood", 5]]}

      saved =
        saved
        |> Map.update!("sites", &[site | &1])
        |> Map.update!("next_id", &max(&1, 901))

      Repo.update_all(from(r in UniverseRecord, where: r.gx == 0 and r.gy == 0),
        set: [state: Jason.encode!(saved)]
      )

      :ok = Sim.reset(@plaza)
      {reply, _, actions} = enter(socket, "maker", [2.5, -0.5, 0])
      assert [%{id: 900, kind: "dresser", have: [["wood", 5]], need: []}] = reply.sites
      assert Sim.block(@plaza, {3, -2, 0}) == World.block_ids()["scaffold"]
      wood = count(reply.bag, "wood")

      ref = push(actions, "break_action", %{"site" => 900})
      assert_reply(ref, :ok, %{returned: [["wood", 5]], sack: nil, bag: bag})
      assert count(bag, "wood") == wood + 5
      assert_broadcast("site_gone", %{id: 900})
      assert Sim.block(@plaza, {2, -2, 0}) == 0
      assert Sim.snapshot(@plaza).sites == []
    end
  end

  describe "sheep" do
    test "shorn for wool within reach, once until it grows back", %{socket: socket} do
      :ok = Sim.reset(@plaza, sheep: 2)
      {reply, _, actions} = enter(socket, "maker")
      assert [%{id: a, x: x, y: y, z: z, woolly: true}, %{id: b} = other] = reply.sheep

      stand(actions, [x + 10, y, z])
      ref = push(actions, "shear_action", %{"sheep" => a})
      assert_reply(ref, :error, %{reason: "out_of_reach"})

      stand(actions, [x - 1, y, z])
      ref = push(actions, "shear_action", %{"sheep" => a})
      assert_reply(ref, :ok, %{wool: 3, bag: bag})
      assert count(bag, "wool") == 3
      assert_broadcast("wool", %{id: ^a, woolly: false})

      ref = push(actions, "shear_action", %{"sheep" => a})
      assert_reply(ref, :error, %{reason: "already_shorn"})
      ref = push(actions, "shear_action", %{"sheep" => 9999})
      assert_reply(ref, :error, %{reason: "no_such_sheep"})
      ref = push(actions, "shear_action", %{"sheep" => "a"})
      assert_reply(ref, :error, %{reason: "bad_request"})

      Players.put_bag("maker", List.duplicate({"dirt", 64}, 16))
      stand(actions, [other.x - 1, other.y, other.z])
      ref = push(actions, "shear_action", %{"sheep" => b})
      assert_reply(ref, :error, %{reason: "bag_full"})

      # and they wander, broadcast like cows
      :ok = Sim.tick(@plaza, now())
      assert_broadcast("sheep", %{rows: [[_, _, _, _, _] | _]})
    end
  end
end
