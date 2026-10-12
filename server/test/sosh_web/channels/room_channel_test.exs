defmodule SoshWeb.RoomChannelTest do
  # Not async: Sosh.Lobby is one shared registry.
  use SoshWeb.ChannelCase

  alias Sosh.Lobby

  setup do
    Enum.each(Lobby.list(), &Lobby.delete(&1.user_id))
    :ok
  end

  defp join_as(socket, name, extra \\ %{}) do
    params = Map.merge(%{"name" => name, "vec" => [1.5, -2, 0]}, extra)
    {:ok, reply, socket} = subscribe_and_join(socket, SoshWeb.RoomChannel, "room:lobby", params)
    {reply, socket}
  end

  test "join assigns an id, registers the player and announces them", %{socket: socket} do
    {reply, socket} = join_as(socket, "  ada  ", %{"face" => 3})
    id = reply.user_id

    assert socket.assigns.user_id == id
    assert_push("snapshot", %{players: players})
    assert [%{user_id: ^id, name: "ada", vec: [1.5, -2, 0], face: 3, animation: 0}] = players
    assert_broadcast("joined", %{user_id: ^id, name: "ada"})
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
      subscribe_and_join(socket, SoshWeb.RoomChannel, "room:lobby", %{
        "name" => String.duplicate("x", 40),
        "vec" => [1, "two", 3],
        "face" => 999
      })

    assert [%{name: name, at: [0, 0, 0], face: 0}] = Lobby.list()
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

    # clamped to the plaza, and to running speed
    assert [%{user_id: ^id, at: [100, 2, 0], v: [6.0, +0.0], to: [9, 2]} = me] = Lobby.list()
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

  test "other rooms are refused", %{socket: socket} do
    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, SoshWeb.RoomChannel, "room:secret", %{})
  end
end
