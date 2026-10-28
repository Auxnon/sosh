defmodule Sosh.Servers do
  @moduledoc """
  Servers are universes of the grid with members, Discord style. Each has a
  policy for who gets in:

    * `"open"` - anyone who asks is a member
    * `"friends"` - the owner's friends are let straight in (the allowlist);
      anyone else waits, `pending`, for someone who can approve
    * `"approval"` - everyone waits for approval

  Someone can also be `invited` by a member who may invite: accepting
  (`join/2`) makes them a member whatever the policy. `banned` people can't
  ask again.

  Roles, highest first, and what each may do (each has its own and every
  lower role's permissions):

    * `member` - `:enter` the universe, `:chat`, `:build`, `:send_items`
    * `moderator` - `:approve` requests, `:kick`, `:manage_messages`
    * `admin` - `:invite`, `:ban`, `:set_roles` (up to moderator)
    * `owner` - `:manage_server` (name, description, policy), `:set_roles`
      up to admin

  Nobody acts on someone of their own role or higher. The world was seeded
  with ten open servers (`seed/0`), owned by no one; a world-creation
  system comes later.

  Changes go out on `user:<id>` (`servers`) for the people affected and on
  `server:<id>` (`members`) for everyone there.
  """
  import Ecto.Query

  alias Sosh.{Accounts, Friends, Repo, Universes}
  alias Sosh.Accounts.User
  alias Sosh.Social.{Membership, Server}

  @roles ~w(member moderator admin owner)
  @perms %{
    "member" => [:enter, :chat, :build, :send_items],
    "moderator" => [:approve, :kick, :manage_messages],
    "admin" => [:invite, :ban, :set_roles],
    "owner" => [:manage_server]
  }

  # The ten the world starts with: a 5x2 block of the grid around the plaza.
  @seeds [
    {{0, 0}, "sea", "Plaza", "Where everyone starts: the old plaza island over the sea."},
    {{1, 0}, "land", "Eastreach", "Wild land below and islands to build on."},
    {{2, 0}, "sea", "Saltwind", "Open water and steady winds for airships."},
    {{3, 0}, "land", "Copperfield", "Farmland islands over copper hills."},
    {{4, 0}, "sea", "Lanternfall", "The far east edge of the map."},
    {{0, 1}, "land", "Mossbank", "Green islands north of the plaza."},
    {{1, 1}, "sea", "Driftwood", "A scatter of small islands."},
    {{2, 1}, "land", "Highmoor", "High, windy islands over moorland."},
    {{3, 1}, "sea", "Thistledown", "Quiet islands for building."},
    {{4, 1}, "land", "Windward", "The north-east corner of the world."}
  ]

  def roles, do: @roles

  @doc "Every permission `role` has."
  def perms(role) do
    @roles
    |> Enum.take_while(&(&1 != role))
    |> Kernel.++([role])
    |> Enum.flat_map(&Map.get(@perms, &1, []))
  end

  defp rank(role), do: Enum.find_index(@roles, &(&1 == role)) || -1

  # -- seeding

  @doc "Make sure the seeded universes and their servers exist."
  def seed do
    for {{gx, gy} = u, kind, name, about} <- @seeds do
      unless Universes.exists?(u), do: Universes.create(u, kind)

      Repo.insert!(
        %Server{name: name, gx: gx, gy: gy, policy: "open", description: about},
        on_conflict: :nothing,
        conflict_target: [:gx, :gy]
      )
    end

    :ok
  end

  @doc "The plaza's server: where new players start."
  def home, do: Repo.get_by(Server, gx: 0, gy: 0)

  # -- lookups

  def get(id), do: Repo.get(Server, id)

  def at({gx, gy}), do: Repo.get_by(Server, gx: gx, gy: gy)

  def membership(server_id, user_id),
    do: Repo.get_by(Membership, server_id: server_id, user_id: user_id)

  @doc "`role` if `user` is a member of the server, else nil."
  def role(%Server{} = s, user_id) do
    case membership(s.id, user_id) do
      %Membership{status: "member", role: r} -> r
      _ -> nil
    end
  end

  def can?(%Server{} = s, user_id, perm) do
    case role(s, user_id) do
      nil -> false
      r -> perm in perms(r)
    end
  end

  @doc "May `user` be in universe `u`? A universe with no server is anyone's."
  def may_enter?({_, _} = u, user_id) do
    case at(u) do
      nil -> true
      s -> can?(s, user_id, :enter)
    end
  end

  @doc "Every server, as `user` sees it: `[%{id, name, ..., status, role}]`."
  def list(%User{id: me}) do
    mine =
      Repo.all(from m in Membership, where: m.user_id == ^me)
      |> Map.new(&{&1.server_id, &1})

    counts =
      Repo.all(
        from m in Membership,
          where: m.status == "member",
          group_by: m.server_id,
          select: {m.server_id, count(m.id)}
      )
      |> Map.new()

    Repo.all(from s in Server, order_by: [s.gy, s.gx])
    |> Enum.map(fn s ->
      m = mine[s.id]

      public(s)
      |> Map.merge(%{
        status: m && m.status,
        role: m && m.status == "member" && m.role,
        members: Map.get(counts, s.id, 0)
      })
    end)
  end

  def public(%Server{} = s) do
    %{
      id: s.id,
      name: s.name,
      description: s.description,
      universe: [s.gx, s.gy],
      policy: s.policy,
      owner_id: s.owner_id
    }
  end

  @doc "Members and requests: `[%{user, role, status}]`, members first by rank."
  def members(%Server{} = s, viewer_id) do
    # only those who may approve see who's waiting
    see_waiting = can?(s, viewer_id, :approve)

    Repo.all(from m in Membership, where: m.server_id == ^s.id, preload: :user)
    |> Enum.filter(&(&1.status == "member" or see_waiting))
    |> Enum.sort_by(&{&1.status != "member", -rank(&1.role), String.downcase(&1.user.handle)})
    |> Enum.map(&%{user: User.public(&1.user), role: &1.role, status: &1.status})
  end

  # -- joining

  @doc """
  Ask to join, or accept an invitation: `{:ok, "member" | "pending"}` or
  `{:error, :banned | :no_such_server}`.
  """
  def join(%User{} = me, server_id) do
    with %Server{} = s <- get(server_id) || {:error, :no_such_server} do
      case membership(s.id, me.id) do
        %Membership{status: "member"} ->
          {:ok, "member"}

        %Membership{status: "banned"} ->
          {:error, :banned}

        %Membership{status: "invited"} = m ->
          set(m, status: "member")
          changed(s, [me.id])
          {:ok, "member"}

        %Membership{status: "pending"} ->
          {:ok, "pending"}

        nil ->
          status = if straight_in?(s, me), do: "member", else: "pending"
          role = if s.owner_id == me.id, do: "owner", else: "member"
          Repo.insert!(%Membership{server_id: s.id, user_id: me.id, status: status, role: role})
          changed(s, [me.id | approvers(s)])
          {:ok, status}
      end
    end
  end

  defp straight_in?(s, me) do
    cond do
      s.owner_id == me.id -> true
      s.policy == "open" -> true
      s.policy == "friends" and s.owner_id != nil -> Friends.friends?(s.owner_id, me.id)
      true -> false
    end
  end

  @doc "Make sure `user` is a member of the plaza, where everyone starts."
  def join_home(%User{} = me) do
    case home() do
      nil -> :ok
      s -> join(me, s.id)
    end
  end

  @doc "Leave (or withdraw a request). The owner can't leave their own server."
  def leave(%User{} = me, server_id) do
    with %Server{} = s <- get(server_id) || {:error, :no_such_server} do
      case membership(s.id, me.id) do
        %Membership{role: "owner", status: "member"} ->
          {:error, :owner_cant_leave}

        %Membership{status: "banned"} ->
          :ok

        nil ->
          :ok

        m ->
          Repo.delete!(m)
          changed(s, [me.id])
          :ok
      end
    end
  end

  # -- managing members

  @doc "Let someone waiting in."
  def approve(%User{} = me, server_id, handle),
    do: act(me, server_id, handle, :approve, fn m -> m.status == "pending" end, status: "member")

  @doc "Turn down someone waiting."
  def reject(%User{} = me, server_id, handle),
    do: act(me, server_id, handle, :approve, fn m -> m.status == "pending" end, :delete)

  def kick(%User{} = me, server_id, handle),
    do: act(me, server_id, handle, :kick, fn m -> m.status == "member" end, :delete)

  def ban(%User{} = me, server_id, handle),
    do: act(me, server_id, handle, :ban, fn _ -> true end, status: "banned", role: "member")

  def unban(%User{} = me, server_id, handle),
    do: act(me, server_id, handle, :ban, fn m -> m.status == "banned" end, :delete)

  @doc "Give a member a role below your own (and at most admin)."
  def set_role(%User{} = me, server_id, handle, role) when role in @roles do
    with %Server{} = s <- get(server_id) || {:error, :no_such_server},
         my_role when my_role != nil <- role(s, me.id) || {:error, :not_member},
         true <- (:set_roles in perms(my_role) and rank(role) < rank(my_role)) || {:error, :forbidden} do
      act(me, server_id, handle, :set_roles, fn m -> m.status == "member" end, role: role)
    end
  end

  def set_role(_, _, _, _), do: {:error, :no_such_role}

  @doc "Invite someone; they join when they accept (`join/2`)."
  def invite(%User{} = me, server_id, handle) do
    with %Server{} = s <- get(server_id) || {:error, :no_such_server},
         true <- can?(s, me.id, :invite) || {:error, :forbidden},
         %User{} = them <- Accounts.get_by_handle(handle) || {:error, :no_such_user} do
      case membership(s.id, them.id) do
        nil ->
          Repo.insert!(%Membership{server_id: s.id, user_id: them.id, status: "invited"})
          changed(s, [them.id])
          :ok

        %Membership{status: "pending"} = m ->
          set(m, status: "member")
          changed(s, [them.id])
          :ok

        %Membership{status: "banned"} ->
          {:error, :banned}

        _ ->
          :ok
      end
    end
  end

  @doc "Rename, describe or change the policy: owners only."
  def update(%User{} = me, server_id, attrs) do
    with %Server{} = s <- get(server_id) || {:error, :no_such_server},
         true <- can?(s, me.id, :manage_server) || {:error, :forbidden},
         {:ok, s} <- s |> Server.changeset(attrs) |> Repo.update() do
      changed(s, [])
      {:ok, s}
    end
  end

  @doc """
  Hand a server to someone (the seeded ones have no owner until given one,
  from the console: `Sosh.Servers.give(server_id, "handle")`).
  """
  def give(server_id, handle) do
    with %Server{} = s <- get(server_id) || {:error, :no_such_server},
         %User{} = u <- Accounts.get_by_handle(handle) || {:error, :no_such_user} do
      Repo.transaction(fn ->
        if s.owner_id do
          from(m in Membership, where: m.server_id == ^s.id and m.user_id == ^s.owner_id)
          |> Repo.update_all(set: [role: "admin"])
        end

        s |> Ecto.Changeset.change(owner_id: u.id) |> Repo.update!()

        Repo.insert!(
          %Membership{server_id: s.id, user_id: u.id, status: "member", role: "owner"},
          on_conflict: [set: [status: "member", role: "owner"]],
          conflict_target: [:server_id, :user_id]
        )
      end)

      changed(s, [u.id])
      :ok
    end
  end

  # Do `change` to `handle`'s membership if `me` has `perm`, outranks them
  # and `ok?` holds for their membership.
  defp act(me, server_id, handle, perm, ok?, change) do
    with %Server{} = s <- get(server_id) || {:error, :no_such_server},
         true <- can?(s, me.id, perm) || {:error, :forbidden},
         %User{} = them <- Accounts.get_by_handle(handle) || {:error, :no_such_user},
         true <- them.id != me.id || {:error, :yourself} do
      m = membership(s.id, them.id)

      cond do
        perm == :ban and m == nil ->
          Repo.insert!(%Membership{server_id: s.id, user_id: them.id, status: "banned"})
          changed(s, [them.id])
          kicked(s, them.id)
          :ok

        m == nil or not ok?.(m) ->
          {:error, :not_applicable}

        m.status == "member" and rank(m.role) >= rank(role(s, me.id)) ->
          {:error, :forbidden}

        true ->
          case change do
            :delete -> Repo.delete!(m)
            kv -> set(m, kv)
          end

          changed(s, [them.id])
          if perm in [:kick, :ban], do: kicked(s, them.id)
          :ok
      end
    end
  end

  defp set(m, kv), do: m |> Ecto.Changeset.change(kv) |> Repo.update!()

  defp approvers(s) do
    Repo.all(
      from m in Membership,
        where: m.server_id == ^s.id and m.status == "member" and m.role in ["moderator", "admin", "owner"],
        select: m.user_id
    )
  end

  defp changed(s, user_ids) do
    for id <- Enum.uniq(user_ids), do: SoshWeb.Endpoint.broadcast("user:#{id}", "servers", %{})
    SoshWeb.Endpoint.broadcast("server:#{s.id}", "members", %{})
  end

  # Whoever was removed leaves its universe and its chat now.
  defp kicked(s, user_id) do
    SoshWeb.Endpoint.broadcast("user:#{user_id}", "removed", %{server_id: s.id, universe: [s.gx, s.gy]})
  end
end
