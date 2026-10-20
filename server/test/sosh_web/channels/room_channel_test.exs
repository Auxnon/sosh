defmodule SoshWeb.RoomChannelTest do
  # Not async: Sosh.Lobby is one shared registry.
  use SoshWeb.ChannelCase

  alias Sosh.{Lobby, Players}

  defp join_as(socket, name, extra \\ %{}) do
    params = Map.merge(%{"name" => name}, extra)
    {:ok, reply, socket} = subscribe_and_join(socket, SoshWeb.RoomChannel, "room:0,0", params)
    {reply, socket}
  end

  test "join assigns an id, registers the player and announces them", %{socket: socket} do
    {reply, socket} = join_as(socket, "  ada  ", %{"face" => 3})
    id = reply.user_id

    assert socket.assigns.user_id == id
    # a newcomer stands on the plaza, near the middle
    assert %{universe: [0, 0], at: [x, y, z] = at} = reply
    assert abs(x) <= 2 and abs(y) <= 2 and z == 0.0
    assert_push("snapshot", %{players: players})
    assert [%{user_id: ^id, name: "ada", vec: ^at, face: 3, animation: 0}] = players
    assert_broadcast("joined", %{user_id: ^id, name: "ada"})
  end

  test "players come back where they left off", %{socket: socket} do
    {_, socket} = join_as(socket, "ada")
    push(socket, "move", %{"at" => [-5.5, 3, 0], "v" => [0, 0]})
    :sys.get_state(socket.channel_pid)
    Process.unlink(socket.channel_pid)
    leave(socket)
    assert_broadcast("left", _)

    {:ok, again} = connect(SoshWeb.UserSocket, %{})
    {reply, _} = join_as(again, "ada")
    assert reply.at == [-5.5, 3.0, 0.0]
  end

  test "a player is in one universe at a time", %{socket: socket} do
    assert {:error, %{reason: "elsewhere", universe: [0, 0]}} =
             subscribe_and_join(socket, SoshWeb.RoomChannel, "room:1,0", %{"name" => "ada"})

    # flown east (Sosh.Sim moves them when their ship crosses over)
    Players.move("ada", {1, 0})

    assert {:error, %{reason: "elsewhere", universe: [1, 0]}} =
             subscribe_and_join(socket, SoshWeb.RoomChannel, "room:0,0", %{"name" => "ada"})

    {:ok, reply, _} =
      subscribe_and_join(socket, SoshWeb.RoomChannel, "room:1,0", %{"name" => "ada"})

    assert reply.universe == [1, 0]
    assert [%{universe: {1, 0}}] = Lobby.list()
    assert Lobby.list({0, 0}) == []
  end

  test "someone whose universe is gone from the grid is back on the plaza", %{socket: socket} do
    Players.move("ada", {9, 9})

    assert {:error, %{reason: "elsewhere", universe: [0, 0]}} =
             subscribe_and_join(socket, SoshWeb.RoomChannel, "room:9,9", %{"name" => "ada"})

    assert {:ok, %{universe: [0, 0]}, _} =
             subscribe_and_join(socket, SoshWeb.RoomChannel, "room:0,0", %{"name" => "ada"})
  end

  test "a newcomer's snapshot includes players already present", %{socket: socket} do
    {first, _} = join_as(socket, "first")
    {:ok, other} = connect(SoshWeb.UserSocket, %{})
    {second, _} = join_as(other, "second")

    ids = [first.user_id, second.user_id] |> Enum.sort()
    assert_push("snapshot", %{players: [_]})
    assert_push("snapshot", %{players: players})
    assert players |> Enum.map(& &1.user_id) |> Enum.sort() == ids
  end

  test "join params are sanitised", %{socket: socket} do
    {:ok, _, _} =
      subscribe_and_join(socket, SoshWeb.RoomChannel, "room:0,0", %{
        "name" => String.duplicate("x", 40),
        "face" => 999
      })

    assert [%{name: name, face: 0}] = Lobby.list()
    assert String.length(name) == 16
  end

  test "move, face and animation update the lobby and reach others", %{socket: socket} do
    {reply, socket} = join_as(socket, "mover")
    id = reply.user_id

    push(socket, "move", %{"at" => [500, 2, 0], "v" => [30, 0], "to" => [9, 2]})
    push(socket, "face", %{"face" => 5})
    push(socket, "animation", %{"animation" => 2})
    # pushes are processed in order; a sync message waits for all three
    :sys.get_state(socket.channel_pid)

    # clamped to the universe, and to running speed
    assert [%{user_id: ^id, at: [49, 2, 0], v: [6.0, +0.0], to: [9, 2]} = me] = Lobby.list()
    assert %{face: 5, animation: 2} = me
  end

  test "move is broadcast to others; garbage velocity means standing still", %{socket: socket} do
    {reply, socket} = join_as(socket, "mover")
    id = reply.user_id

    push(socket, "move", %{"at" => [1, 2, 0], "v" => [1.5, -2]})
    assert_broadcast("move", %{user_id: ^id, at: [1, 2, 0], v: [1.5, -2], to: nil})

    push(socket, "move", %{"at" => [1, 2, 0], "v" => "fast", "to" => [1]})
    assert_broadcast("move", %{v: [0, 0], to: nil})
  end

  test "positions are predicted from the last report" do
    p = %{at: [0, 0, 1], v: [2, 0], to: nil, t: 1_000}
    assert Lobby.position(p, 1_000) == [0.0, 0.0, 1]
    assert Lobby.position(p, 1_500) == [1.0, 0.0, 1]
    # no further than the horizon without a fresh report
    assert Lobby.position(p, 9_000) == [3.0, 0.0, 1]
    # and no further than the destination
    assert Lobby.position(%{p | to: [0.5, 0]}, 2_000) == [0.5, 0, 1]
    # standing still
    assert Lobby.position(%{at: [3, 4, 0]}, 5_000) == [3, 4, 0]
  end

  test "chat is trimmed, capped and echoed with the sender's name", %{socket: socket} do
    {reply, socket} = join_as(socket, "talker")
    id = reply.user_id

    push(socket, "new_msg", %{"body" => "  hello  "})
    assert_broadcast("new_msg", %{body: "hello", user_id: ^id, name: "talker"})

    push(socket, "new_msg", %{"body" => String.duplicate("a", 400)})
    assert_broadcast("new_msg", %{body: body})
    assert String.length(body) == 280

    push(socket, "new_msg", %{"body" => "   "})
    refute_broadcast("new_msg", _)
  end

  test "leaving removes the player and tells the room", %{socket: socket} do
    {reply, socket} = join_as(socket, "leaver")
    id = reply.user_id

    Process.unlink(socket.channel_pid)
    ref = leave(socket)
    assert_reply(ref, :ok)
    assert_broadcast("left", %{user_id: ^id})
    assert Lobby.list() == []
  end

  test "emotes reach others; unknown ones are ignored", %{socket: socket} do
    {reply, socket} = join_as(socket, "dancer")
    id = reply.user_id

    push(socket, "emote", %{"emote" => "dance"})
    assert_broadcast("emote", %{emote: "dance", user_id: ^id})

    push(socket, "emote", %{"emote" => "moonwalk"})
    refute_broadcast("emote", _)
  end

  test "the room uses the socket's user id", %{socket: socket} do
    {reply, _} = join_as(socket, "same")
    assert reply.user_id == socket.assigns.user_id
  end

  test "rooms that aren't universes are refused", %{socket: socket} do
    assert {:error, %{reason: "no_such_universe"}} =
             subscribe_and_join(socket, SoshWeb.RoomChannel, "room:secret", %{})
  end
end
