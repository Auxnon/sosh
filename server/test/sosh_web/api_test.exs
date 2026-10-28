defmodule SoshWeb.ApiTest do
  # Not async: the rate limiter and players are app-wide.
  use SoshWeb.ConnCase

  alias Sosh.{Players, RateLimit, Servers}

  setup do
    Players.reset()
    RateLimit.reset()
    Sosh.Sim.stop_all()
    Servers.seed()
    :ok
  end

  # The code in the last email sent to `email`.
  defp code_for(email) do
    assert_received {:email, %{to: [{_, ^email}], subject: subject}}
    [code] = Regex.run(~r/\d{6}/, subject)
    code
  end

  defp signup(conn, handle) do
    email = "#{String.downcase(handle)}@example.com"

    conn
    |> post("/api/auth/register", %{email: email, handle: handle, password: "a long passphrase"})
    |> json_response(201)

    %{"token" => token} =
      build_conn()
      |> post("/api/auth/confirm", %{email: email, code: code_for(email)})
      |> json_response(200)

    token
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer " <> token)

  describe "accounts" do
    test "sign up, confirm by emailed code, then everything", %{conn: conn} do
      assert %{"status" => "confirm"} =
               conn
               |> post("/api/auth/register", %{
                 email: " Ada@Example.com ",
                 handle: "ada",
                 password: "a long passphrase"
               })
               |> json_response(201)

      code = code_for("ada@example.com")

      # not before confirming
      assert %{"error" => "unconfirmed"} =
               build_conn()
               |> post("/api/auth/login", %{email: "ada@example.com", password: "a long passphrase"})
               |> json_response(403)

      # that login sent a fresh code; the first is dead
      fresh = code_for("ada@example.com")
      assert %{"error" => "bad_code"} =
               build_conn() |> post("/api/auth/confirm", %{email: "ada@example.com", code: code}) |> json_response(422)

      assert %{"token" => token, "user" => %{"handle" => "ada", "confirmed" => true}} =
               build_conn()
               |> post("/api/auth/confirm", %{email: "ADA@example.com", code: fresh})
               |> json_response(200)

      me = authed(token) |> get("/api/me") |> json_response(200)
      assert me["user"]["email"] == "ada@example.com"
      assert length(me["servers"]) == 10
      # signed in: a member of the plaza, where everyone starts
      assert %{"status" => "member", "role" => "member"} =
               Enum.find(me["servers"], &(&1["universe"] == [0, 0]))

      assert me["catalog"]["heads"] == Sosh.Character.heads()
      assert me["universe"] == [0, 0]

      assert build_conn() |> get("/api/me") |> json_response(401)
    end

    test "sign-up is validated", %{conn: conn} do
      signup(conn, "taken")

      assert %{"errors" => errors} =
               build_conn()
               |> post("/api/auth/register", %{email: "nope", handle: "x!", password: "short"})
               |> json_response(422)

      assert Map.keys(errors) |> Enum.sort() == ["email", "handle", "password"]

      assert %{"errors" => %{"handle" => ["has already been taken"]}} =
               build_conn()
               |> post("/api/auth/register", %{
                 email: "other@example.com",
                 handle: "TAKEN",
                 password: "a long passphrase"
               })
               |> json_response(422)
    end

    test "sign in, wrong passwords, unknown emails and rate limits", %{conn: conn} do
      signup(conn, "bea")

      assert %{"token" => _} =
               build_conn()
               |> post("/api/auth/login", %{email: "bea@example.com", password: "a long passphrase"})
               |> json_response(200)

      # a wrong password and an unknown email look the same
      for email <- ["bea@example.com", "nobody@example.com"] do
        assert %{"error" => "bad_login"} =
                 build_conn()
                 |> post("/api/auth/login", %{email: email, password: "wrong wrong wrong"})
                 |> json_response(401)
      end

      for _ <- 1..8 do
        build_conn() |> post("/api/auth/login", %{email: "bea@example.com", password: "nope nope nope"})
      end

      assert %{"error" => "rate_limited"} =
               build_conn()
               |> post("/api/auth/login", %{email: "bea@example.com", password: "a long passphrase"})
               |> json_response(429)
    end

    test "a reset code sets a new password and signs every session out", %{conn: conn} do
      old = signup(conn, "cyd")
      assert authed(old) |> get("/api/me") |> json_response(200)

      assert build_conn() |> post("/api/auth/forgot", %{email: "cyd@example.com"}) |> json_response(200)
      # nothing tells an unknown address apart
      assert build_conn() |> post("/api/auth/forgot", %{email: "who@example.com"}) |> json_response(200)
      code = code_for("cyd@example.com")

      assert %{"token" => new} =
               build_conn()
               |> post("/api/auth/reset", %{email: "cyd@example.com", code: code, password: "another long one"})
               |> json_response(200)

      assert authed(old) |> get("/api/me") |> json_response(401)
      assert authed(new) |> get("/api/me") |> json_response(200)

      assert %{"token" => _} =
               build_conn()
               |> post("/api/auth/login", %{email: "cyd@example.com", password: "another long one"})
               |> json_response(200)
    end

    test "codes die after five wrong guesses", %{conn: conn} do
      conn |> post("/api/auth/register", %{email: "d@example.com", handle: "dee", password: "a long passphrase"})
      code = code_for("d@example.com")

      for _ <- 1..5 do
        build_conn() |> post("/api/auth/confirm", %{email: "d@example.com", code: "000000"})
      end

      assert %{"error" => "bad_code"} =
               build_conn() |> post("/api/auth/confirm", %{email: "d@example.com", code: code}) |> json_response(422)
    end

    test "logging out ends the session", %{conn: conn} do
      t = signup(conn, "eve")
      assert authed(t) |> delete("/api/auth/session") |> json_response(200)
      assert authed(t) |> get("/api/me") |> json_response(401)
    end

    test "characters are cleaned and the hand has to hold something in the bag", %{conn: conn} do
      t = signup(conn, "fay")

      %{"user" => %{"character" => c}} =
        authed(t)
        |> put("/api/me/character", %{
          character: %{
            "height" => 9,
            "head" => "square",
            "skin" => "#a0b0c0",
            "face" => [%{"part" => "eye", "shape" => 99, "x" => 5}, %{"part" => "laser"}],
            "top" => "cape",
            "hand" => "wood"
          }
        })
        |> json_response(200)

      assert c["height"] == 1.2
      assert c["head"] == "square"
      assert c["skin"] == "A0B0C0"
      assert [%{"part" => "eye", "shape" => 5, "x" => 1.0}] = c["face"]
      assert c["top"] == "tee"
      # the starter bag has wood
      assert c["hand"] == "wood"

      %{"user" => %{"character" => c}} =
        authed(t) |> put("/api/me/character", %{character: %{"hand" => "chest"}}) |> json_response(200)

      assert c["hand"] == nil
    end
  end

  describe "friends" do
    test "ask, accept, unfriend", %{conn: conn} do
      a = signup(conn, "gus")
      b = signup(conn, "hal")

      assert %{"status" => "requested"} = authed(a) |> post("/api/friends", %{handle: "HAL"}) |> json_response(200)
      assert %{"incoming" => [%{"handle" => "gus"}]} = authed(b) |> get("/api/friends") |> json_response(200)
      assert %{"outgoing" => [%{"handle" => "hal"}]} = authed(a) |> get("/api/friends") |> json_response(200)

      assert authed(b) |> post("/api/friends/gus/accept") |> json_response(200)
      assert %{"friends" => [%{"handle" => "hal"}]} = authed(a) |> get("/api/friends") |> json_response(200)

      assert authed(a) |> delete("/api/friends/hal") |> json_response(200)
      assert %{"friends" => []} = authed(b) |> get("/api/friends") |> json_response(200)

      assert %{"error" => "no_such_user"} = authed(a) |> post("/api/friends", %{handle: "ghost"}) |> json_response(404)
      assert %{"error" => "yourself"} = authed(a) |> post("/api/friends", %{handle: "gus"}) |> json_response(422)
    end

    test "asking someone who asked you accepts", %{conn: conn} do
      a = signup(conn, "ivy")
      b = signup(conn, "jon")
      authed(a) |> post("/api/friends", %{handle: "jon"})
      assert %{"status" => "accepted"} = authed(b) |> post("/api/friends", %{handle: "ivy"}) |> json_response(200)
    end
  end

  describe "servers" do
    setup %{conn: conn} do
      owner = signup(conn, "owner")
      s = Servers.at({2, 1})
      :ok = Servers.give(s.id, "owner")
      %{owner: owner, server: s}
    end

    defp server_status(token, id) do
      authed(token) |> get("/api/servers") |> json_response(200) |> Map.fetch!("servers")
      |> Enum.find(&(&1["id"] == id))
    end

    test "ten seeded open servers, each a universe", %{owner: owner} do
      servers = authed(owner) |> get("/api/servers") |> json_response(200) |> Map.fetch!("servers")
      assert length(servers) == 10
      assert Enum.all?(servers, &Sosh.Universes.exists?(List.to_tuple(&1["universe"])))
      assert Enum.count(servers, &(&1["policy"] == "open")) == 10
      assert %{"name" => "Plaza", "status" => "member"} = Enum.find(servers, &(&1["universe"] == [0, 0]))
    end

    test "the friends policy: friends straight in, others wait for approval", %{conn: conn, owner: owner, server: s} do
      authed(owner) |> patch("/api/servers/#{s.id}", %{policy: "friends"}) |> json_response(200)
      pal = signup(conn, "pal")
      stranger = signup(conn, "stranger")
      authed(owner) |> post("/api/friends", %{handle: "pal"})
      authed(pal) |> post("/api/friends/owner/accept")

      assert %{"status" => "member"} = authed(pal) |> post("/api/servers/#{s.id}/join") |> json_response(200)
      assert %{"status" => "pending"} = authed(stranger) |> post("/api/servers/#{s.id}/join") |> json_response(200)
      refute Servers.may_enter?({2, 1}, Sosh.Accounts.get_by_handle("stranger").id)

      # members don't see who's waiting; the owner does, and lets them in
      assert %{"members" => ms} = authed(pal) |> get("/api/servers/#{s.id}/members") |> json_response(200)
      refute Enum.any?(ms, &(&1["status"] == "pending"))
      assert %{"error" => "forbidden"} =
               authed(pal) |> post("/api/servers/#{s.id}/members/stranger/approve") |> json_response(403)

      assert authed(owner) |> post("/api/servers/#{s.id}/members/stranger/approve") |> json_response(200)
      assert %{"status" => "member"} = server_status(stranger, s.id)
      assert Servers.may_enter?({2, 1}, Sosh.Accounts.get_by_handle("stranger").id)
    end

    test "roles: moderators kick, admins invite and ban, nobody acts on equals or betters", %{conn: conn, owner: owner, server: s} do
      [mod, adm, a, b] = for h <- ~w(mod adm amy bob), do: signup(conn, h)
      for t <- [mod, adm, a, b], do: authed(t) |> post("/api/servers/#{s.id}/join")

      assert authed(owner) |> post("/api/servers/#{s.id}/members/mod/role", %{role: "moderator"}) |> json_response(200)
      assert authed(owner) |> post("/api/servers/#{s.id}/members/adm/role", %{role: "admin"}) |> json_response(200)
      # admins can't make admins, or touch the owner
      assert authed(adm) |> post("/api/servers/#{s.id}/members/amy/role", %{role: "admin"}) |> json_response(403)
      assert authed(adm) |> post("/api/servers/#{s.id}/members/owner/kick") |> json_response(403)

      assert authed(mod) |> post("/api/servers/#{s.id}/members/amy/kick") |> json_response(200)
      assert %{"status" => nil} = server_status(a, s.id)
      assert authed(mod) |> post("/api/servers/#{s.id}/members/adm/kick") |> json_response(403)
      assert authed(mod) |> post("/api/servers/#{s.id}/members/bob/ban") |> json_response(403)

      assert authed(adm) |> post("/api/servers/#{s.id}/members/bob/ban") |> json_response(200)
      assert %{"error" => "banned"} = authed(b) |> post("/api/servers/#{s.id}/join") |> json_response(403)

      authed(owner) |> patch("/api/servers/#{s.id}", %{policy: "approval"})
      assert authed(adm) |> post("/api/servers/#{s.id}/invite", %{handle: "amy"}) |> json_response(200)
      assert %{"status" => "invited"} = server_status(a, s.id)
      assert %{"status" => "member"} = authed(a) |> post("/api/servers/#{s.id}/join") |> json_response(200)

      assert %{"error" => "forbidden"} = authed(adm) |> patch("/api/servers/#{s.id}", %{name: "Mine"}) |> json_response(403)
      assert %{"error" => "owner_cant_leave"} = authed(owner) |> post("/api/servers/#{s.id}/leave") |> json_response(422)
    end
  end

  describe "chat and gifts" do
    setup %{conn: conn} do
      %{ann: signup(conn, "ann"), ben: signup(conn, "ben"), cat: signup(conn, "cat"), plaza: Servers.home()}
    end

    defp wood(handle), do: for({"wood", n} <- Players.bag(handle), do: n) |> Enum.sum()

    test "server chat history", %{ann: ann, ben: ben, plaza: p} do
      assert %{"message" => %{"body" => "hello"}} =
               authed(ann) |> post("/api/servers/#{p.id}/messages", %{body: " hello "}) |> json_response(200)

      assert %{"messages" => [%{"body" => "hello", "author" => %{"handle" => "ann"}}]} =
               authed(ben) |> get("/api/servers/#{p.id}/messages") |> json_response(200)

      s = Servers.at({4, 1})
      assert %{"error" => "forbidden"} = authed(ann) |> post("/api/servers/#{s.id}/messages", %{body: "hi"}) |> json_response(403)
      assert %{"error" => "forbidden"} = authed(ann) |> get("/api/servers/#{s.id}/messages") |> json_response(403)
    end

    test "a gift in the server chat: everyone sees it wrapped, only its @ opens it", %{ann: ann, ben: ben, cat: cat, plaza: p} do
      before = wood("ann")

      assert %{"message" => %{"id" => id, "gift" => %{"item" => "wood", "count" => 5, "state" => "sealed", "to" => %{"handle" => "ben"}}}} =
               authed(ann)
               |> post("/api/servers/#{p.id}/messages", %{body: "@ben for your house", gift: %{item: "wood", count: 5, to: "ben"}})
               |> json_response(200)

      assert wood("ann") == before - 5

      # others see a wrapped gift for ben, not what's in it
      %{"messages" => [m]} = authed(cat) |> get("/api/servers/#{p.id}/messages") |> json_response(200)
      assert m["gift"] == %{"to" => m["gift"]["to"], "state" => "sealed"}
      %{"messages" => [m]} = authed(ben) |> get("/api/servers/#{p.id}/messages") |> json_response(200)
      refute Map.has_key?(m["gift"], "item")

      assert %{"error" => "not_yours"} = authed(cat) |> post("/api/messages/#{id}/claim") |> json_response(403)
      ben_wood = wood("ben")

      assert %{"message" => %{"gift" => %{"state" => "opened", "item" => "wood", "count" => 5}}} =
               authed(ben) |> post("/api/messages/#{id}/claim") |> json_response(200)

      assert wood("ben") == ben_wood + 5
      assert %{"error" => "already"} = authed(ben) |> post("/api/messages/#{id}/claim") |> json_response(422)
      assert %{"error" => "already"} = authed(ann) |> post("/api/messages/#{id}/cancel") |> json_response(422)
    end

    test "gifts need the items, and can be taken back until opened", %{ann: ann, plaza: p} do
      assert %{"error" => "not_enough"} =
               authed(ann)
               |> post("/api/servers/#{p.id}/messages", %{gift: %{item: "wood", count: 999, to: "ben"}})
               |> json_response(422)

      before = wood("ann")

      %{"message" => %{"id" => id}} =
        authed(ann) |> post("/api/servers/#{p.id}/messages", %{gift: %{item: "wood", count: 3, to: "ben"}}) |> json_response(200)

      assert wood("ann") == before - 3
      assert %{"message" => %{"gift" => %{"state" => "returned"}}} = authed(ann) |> post("/api/messages/#{id}/cancel") |> json_response(200)
      assert wood("ann") == before
    end

    test "direct messages: between people who share a server, gifts included", %{ann: ann, ben: ben, cat: cat} do
      assert %{"message" => %{"conversation_id" => c, "id" => id}} =
               authed(ann)
               |> post("/api/dms/ben/messages", %{body: "psst", gift: %{item: "stone", count: 2, to: "ben"}})
               |> json_response(200)

      assert %{"conversation_id" => ^c, "messages" => [%{"body" => "psst"}]} =
               authed(ben) |> get("/api/dms/ann/messages") |> json_response(200)

      assert %{"conversations" => [%{"with" => %{"handle" => "ann"}}]} = authed(ben) |> get("/api/dms") |> json_response(200)
      assert authed(ben) |> post("/api/messages/#{id}/claim") |> json_response(200)
      # cat isn't in it
      assert %{"error" => "not_yours"} = authed(cat) |> post("/api/messages/#{id}/claim") |> json_response(403)

      # someone sharing nothing with you: no
      Servers.leave(Sosh.Accounts.get_by_handle("cat"), Servers.home().id)
      assert %{"error" => "forbidden"} = authed(ann) |> post("/api/dms/cat/messages", %{body: "hi"}) |> json_response(403)
    end
  end
end
