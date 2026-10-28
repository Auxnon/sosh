defmodule SoshWeb.SocialChannelTest do
  use SoshWeb.ChannelCase

  alias Sosh.{Accounts, Servers}

  setup do
    Servers.seed()
    :ok
  end

  defp code_for(email) do
    assert_received {:email, %{to: [{_, ^email}], subject: subject}}
    [code] = Regex.run(~r/\d{6}/, subject)
    code
  end

  defp signed_in(handle) do
    user = account(handle)
    Servers.join_home(user)
    {:ok, socket} = connect(SoshWeb.UserSocket, %{"token" => Accounts.new_session(user)})
    {socket, user}
  end

  test "the socket signs in by token param or the app's user agent" do
    user = account("tok")
    token = Accounts.new_session(user)

    {:ok, s} = connect(SoshWeb.UserSocket, %{"token" => token})
    assert s.assigns.account.id == user.id

    {:ok, s} =
      connect(SoshWeb.UserSocket, %{}, connect_info: %{user_agent: "Mozilla/5.0 Android sosh-token/#{token}"})

    assert s.assigns.account.id == user.id

    {:ok, s} = connect(SoshWeb.UserSocket, %{"token" => "nonsense-token-nonsense"})
    assert s.assigns.account == nil
  end

  test "signing up and in over auth:lobby, from a socket with no token", %{socket: socket} do
    {:ok, _, auth} = Phoenix.ChannelTest.subscribe_and_join(socket, SoshWeb.AuthChannel, "auth:lobby", %{})

    ref = push(auth, "register", %{"email" => "game@example.com", "handle" => "gamer", "password" => "a long passphrase"})
    assert_reply ref, :ok, %{status: "confirm"}

    ref = push(auth, "register", %{"email" => "game@example.com", "handle" => "x", "password" => "x"})
    assert_reply ref, :error, %{reason: "invalid", message: _}

    ref = push(auth, "confirm", %{"email" => "game@example.com", "code" => code_for("game@example.com")})
    assert_reply ref, :ok, %{token: token, user: %{handle: "gamer"}}

    ref = push(auth, "login", %{"email" => "game@example.com", "password" => "wrong password!"})
    assert_reply ref, :error, %{reason: "bad_login"}

    # the token signs a new socket in
    {:ok, s} = connect(SoshWeb.UserSocket, %{"token" => token})
    assert s.assigns.account.handle == "gamer"

    # and nothing but auth works without one
    assert {:error, %{reason: "signed_out"}} =
             Phoenix.ChannelTest.subscribe_and_join(socket, SoshWeb.UserChannel, "user:1", %{})
  end

  test "user:<id> is only yours, and answers everything" do
    {socket, me} = signed_in("mine")
    {_, other} = signed_in("theirs")

    assert {:ok, %{user: %{handle: "mine"}, servers: servers, bag: [_ | _]}, user_ch} =
             Phoenix.ChannelTest.subscribe_and_join(socket, SoshWeb.UserChannel, "user:#{me.id}", %{})

    assert length(servers) == 10

    assert {:error, %{reason: "forbidden"}} =
             Phoenix.ChannelTest.subscribe_and_join(socket, SoshWeb.UserChannel, "user:#{other.id}", %{})

    ref = push(user_ch, "friend_add", %{"handle" => "theirs"})
    assert_reply ref, :ok, %{status: :requested}
    assert_push "friends", %{}

    ref = push(user_ch, "character", %{"character" => %{"head" => "bean", "height" => 1.1}})
    assert_reply ref, :ok, %{user: %{character: %{"head" => "bean", "height" => 1.1}}}
    assert_push "character", %{character: %{"head" => "bean"}}
  end

  test "server chat over the socket: gifts go out sealed, and the recipient opens them" do
    {sa, _ann} = signed_in("ann")
    {sb, ben} = signed_in("ben")
    plaza = Servers.home()

    {:ok, %{messages: []}, chat_a} =
      Phoenix.ChannelTest.subscribe_and_join(sa, SoshWeb.ServerChannel, "server:#{plaza.id}", %{})

    {:ok, _, user_b} = Phoenix.ChannelTest.subscribe_and_join(sb, SoshWeb.UserChannel, "user:#{ben.id}", %{})

    ref = push(chat_a, "post", %{"body" => "@ben catch", "gift" => %{"item" => "stone", "count" => 4, "to" => "ben"}})
    assert_reply ref, :ok, %{message: %{id: id, gift: %{item: "stone", count: 4, state: "sealed"}}}
    assert_broadcast "message", %{id: ^id, gift: gift}
    refute Map.has_key?(gift, :item)

    ref = push(user_b, "claim", %{"id" => id})
    assert_reply ref, :ok, %{message: %{gift: %{state: "opened", item: "stone", count: 4}}}
    assert_push "bag", %{bag: _}
    assert_broadcast "gift", %{id: ^id, gift: %{state: "opened"}}

    # not a member: no chat
    far = Servers.at({4, 1})
    assert {:error, %{reason: "forbidden"}} =
             Phoenix.ChannelTest.subscribe_and_join(sa, SoshWeb.ServerChannel, "server:#{far.id}", %{})
  end

  test "kicked from a server, its chat closes on you" do
    {_, owner} = signed_in("boss")
    {sm, _} = signed_in("mem")
    s = Servers.at({1, 1})
    :ok = Servers.give(s.id, "boss")
    {:ok, "member"} = Servers.join(Accounts.get_by_handle("mem"), s.id)

    {:ok, _, ch} = Phoenix.ChannelTest.subscribe_and_join(sm, SoshWeb.ServerChannel, "server:#{s.id}", %{})
    Process.unlink(ch.channel_pid)
    ref = Process.monitor(ch.channel_pid)

    :ok = Servers.kick(owner, s.id, "mem")
    assert_push "removed", %{server_id: _}
    assert_receive {:DOWN, ^ref, _, _, _}
  end

  test "saying something in the world puts it in the server's chat, as a bubble too", %{socket: socket} do
    plaza = Servers.home()
    Servers.join_home(account("talker"))

    {:ok, %{user_id: id}, room} = subscribe_and_join(socket, SoshWeb.RoomChannel, "room:0,0", %{"name" => "talker"})
    @endpoint.subscribe("server:#{plaza.id}")

    push(room, "new_msg", %{"body" => "hello world"})
    assert_broadcast "new_msg", %{body: "hello world", user_id: ^id, name: "talker"}
    assert_receive %Phoenix.Socket.Broadcast{event: "message", payload: %{body: "hello world"}}

    assert [%{body: "hello world"}] = Sosh.Chat.history({:server, plaza.id}, nil)
  end

  test "only members of a universe's server can enter it", %{socket: socket} do
    s = Servers.at({1, 0})
    s |> Ecto.Changeset.change(policy: "approval") |> Sosh.Repo.update!()
    user = account("walker")
    Sosh.Players.move("walker", {1, 0})

    # not a member there: back on the plaza
    assert {:error, %{reason: "elsewhere", universe: [0, 0]}} =
             subscribe_and_join(socket, SoshWeb.RoomChannel, "room:1,0", %{"name" => "walker"})

    {:ok, "pending"} = Servers.join(user, s.id)
    refute Servers.may_enter?({1, 0}, user.id)
  end

  test "entering a server moves you to its universe; DMs arrive with their text" do
    {sa, ann} = signed_in("enterer")
    {sb, bob} = signed_in("pen_pal")
    {:ok, _, ua} = Phoenix.ChannelTest.subscribe_and_join(sa, SoshWeb.UserChannel, "user:#{ann.id}", %{})
    {:ok, _, _ub} = Phoenix.ChannelTest.subscribe_and_join(sb, SoshWeb.UserChannel, "user:#{bob.id}", %{})

    far = Servers.at({3, 0})
    ref = push(ua, "enter", %{"id" => far.id})
    assert_reply ref, :error, %{reason: "forbidden"}

    {:ok, "member"} = Servers.join(ann, far.id)
    ref = push(ua, "enter", %{"id" => far.id})
    assert_reply ref, :ok, %{universe: [3, 0]}
    assert Sosh.Players.get("enterer").universe == {3, 0}

    ref = push(ua, "dm_post", %{"handle" => "pen_pal", "body" => "hi there"})
    assert_reply ref, :ok, %{message: %{body: "hi there"}}
    assert_push "dm", %{from: %{handle: "enterer"}, message: %{body: "hi there"}}
  end
end
