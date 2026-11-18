defmodule SoshWeb.CraftingTest do
  use SoshWeb.ChannelCase

  alias Sosh.{Accounts, Players}

  defp signed_in(handle) do
    user = account(handle)
    {:ok, socket} = connect(SoshWeb.UserSocket, %{"token" => Accounts.new_session(user)})
    {:ok, _, ch} = Phoenix.ChannelTest.subscribe_and_join(socket, SoshWeb.UserChannel, "user:#{user.id}", %{})
    {ch, user}
  end

  defp entry(step, at), do: %{"step" => step, "at" => at}

  test "a new player has no crafting and no stations" do
    assert Players.crafting("fresh") == %{}
    assert Players.stations("fresh") == []
  end

  test "crafting is cleaned: bounded names, integer step >= 0 and at, nothing else kept" do
    long = String.duplicate("x", 65)

    {:ok, saved} =
      Players.set_crafting("cleaner", %{
        "bed" => %{"step" => 2, "at" => 100, "junk" => true},
        "atom_keys" => %{step: 1, at: 5},
        "neg" => entry(-1, 1),
        "float" => entry(1.5, 1),
        "no_at" => %{"step" => 1},
        "str_at" => entry(1, "9"),
        "not_map" => 3,
        "" => entry(1, 1),
        long => entry(1, 1),
        7 => entry(1, 1)
      })

    assert saved == %{"bed" => entry(2, 100), "atom_keys" => entry(1, 5)}
    assert Players.crafting("cleaner") == saved
    assert Players.set_crafting("cleaner", "nonsense") == {:ok, %{}}
    assert Players.crafting("cleaner") == %{}
  end

  test "only the 20 most recent by at are kept" do
    map = Map.new(1..25, fn i -> {"r#{i}", entry(i, 1000 + i)} end)
    {:ok, saved} = Players.set_crafting("many", map)
    assert map_size(saved) == 20
    assert Map.keys(saved) |> Enum.sort() == Enum.map(6..25, &"r#{&1}") |> Enum.sort()
    refute Map.has_key?(saved, "r5")
  end

  test "crafting survives a restart of the cache" do
    {:ok, saved} = Players.set_crafting("persist", %{"bed" => entry(3, 42)})
    Players.reset()
    assert Players.crafting("persist") == saved
  end

  test "stations are sorted, de-duplicated and short strings only" do
    {:ok, list} = Players.set_stations("stn", ["loom", "bench", "loom", 5, nil, "", String.duplicate("a", 33)])
    assert list == ["bench", "loom"]
    assert Players.stations("stn") == ["bench", "loom"]

    Players.reset()
    assert Players.stations("stn") == ["bench", "loom"]
    assert {:ok, []} = Players.set_stations("stn", :nope)
  end

  test "leaving the universe empties stations" do
    Players.get("leaver")
    Players.move("leaver", {1, 0})
    Players.set_stations("leaver", ["bench"])
    :ok = Players.left("leaver", {1, 0}, {1.0, 2.0, 3.0})
    assert Players.stations("leaver") == []

    # having moved on elsewhere already, a late "left" from the old one leaves them be
    Players.set_stations("leaver", ["loom"])
    :ok = Players.left("leaver", {0, 0}, {1.0, 2.0, 3.0})
    assert Players.stations("leaver") == ["loom"]

    # moving to another universe empties them too
    Players.move("leaver", {0, 0})
    assert Players.stations("leaver") == []
  end

  test "closing the room channel empties stations" do
    {:ok, _, room} = subscribe_and_join(socket_for("roomer"), SoshWeb.RoomChannel, "room:0,0", %{"name" => "roomer"})
    Players.set_stations("roomer", ["bench"])
    Process.unlink(room.channel_pid)
    ref = Process.monitor(room.channel_pid)
    leave(room)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert Players.stations("roomer") == []
  end

  defp socket_for(handle) do
    {:ok, socket} = connect(SoshWeb.UserSocket, %{})
    as(socket, handle)
  end

  test "crafting event replies with the recipes and stations" do
    {ch, _} = signed_in("booker")
    Players.set_crafting("booker", %{"bed" => entry(2, 10)})
    Players.set_stations("booker", ["loom", "bench"])

    ref = push(ch, "crafting", %{})
    assert_reply ref, :ok, %{crafting: %{"bed" => %{"step" => 2, "at" => 10}}, stations: ["bench", "loom"]}
  end

  test "set_crafting saves, replies the cleaned map and pushes to the account" do
    {ch, _} = signed_in("setter")

    ref = push(ch, "set_crafting", %{"crafting" => %{"bed" => entry(1, 7), "bad" => entry(-3, 7)}})
    assert_reply ref, :ok, %{crafting: %{"bed" => %{"step" => 1, "at" => 7}} = saved}
    assert map_size(saved) == 1
    assert Players.crafting("setter") == saved
    assert_push "crafting", %{crafting: ^saved}

    # nothing changed: nothing pushed
    ref = push(ch, "set_crafting", %{"crafting" => %{"bed" => entry(1, 7)}})
    assert_reply ref, :ok, %{crafting: ^saved}
    refute_push "crafting", _

    ref = push(ch, "set_crafting", %{"crafting" => "x"})
    assert_reply ref, :error, %{reason: "bad_request"}
  end

  test "set_stations pushes only on a change, and clearing on leaving pushes too" do
    {_ch, _} = signed_in("pusher")

    Players.set_stations("pusher", ["loom", "bench"])
    assert_push "stations", %{stations: ["bench", "loom"]}

    Players.set_stations("pusher", ["bench", "loom", "bench"])
    refute_push "stations", _

    Players.move("pusher", {1, 0})
    assert_push "stations", %{stations: []}

    Players.move("pusher", {0, 0})
    refute_push "stations", _
  end

  test "pushes reach a player's other devices and nobody else" do
    {_a, _} = signed_in("twin")
    {_b, _} = signed_in("twin")
    {_c, _} = signed_in("other")

    Players.set_crafting("twin", %{"bed" => entry(1, 1)})
    # both of twin's channels subscribe to the same topic, so both get it
    assert_push "crafting", _
    assert_push "crafting", _
    refute_push "crafting", _
  end
  test "the catalog is there outside a world" do
    {ch, _} = signed_in("cataloguer")
    ref = push(ch, "catalog", %{})
    assert_reply ref, :ok, %{catalog: %{recipes: [_ | _], stations: [_ | _]}}
  end
end
