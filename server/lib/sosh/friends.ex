defmodule Sosh.Friends do
  @moduledoc """
  Friends: one asks (`request/2`), the other accepts (`accept/2`) or either
  removes it (`remove/2`). Asking someone who already asked you accepts
  theirs. Friends can message each other directly and, on servers with the
  `"friends"` policy, the owner's friends join without waiting for approval
  (`Sosh.Servers`).

  Changes are announced on each person's `user:<id>` topic as
  `friends` events, so their clients refresh.
  """
  import Ecto.Query

  alias Sosh.Accounts
  alias Sosh.Accounts.User
  alias Sosh.Repo
  alias Sosh.Social.Friendship

  @max_friends 500

  @doc "Friends and requests both ways: `%{friends, incoming, outgoing}` of public users."
  def list(%User{id: me}) do
    rows =
      Repo.all(
        from f in Friendship,
          where: f.user_id == ^me or f.friend_id == ^me,
          preload: [:user, :friend]
      )

    Enum.reduce(rows, %{friends: [], incoming: [], outgoing: []}, fn f, acc ->
      other = if f.user_id == me, do: f.friend, else: f.user
      key =
        cond do
          f.status == "accepted" -> :friends
          f.user_id == me -> :outgoing
          true -> :incoming
        end

      Map.update!(acc, key, &[User.public(other) | &1])
    end)
    |> Map.new(fn {k, v} -> {k, Enum.sort_by(v, &String.downcase(&1.handle))} end)
  end

  def friends?(a, b) when a == b, do: false

  def friends?(a, b) do
    Repo.exists?(
      from f in Friendship,
        where:
          f.status == "accepted" and
            ((f.user_id == ^a and f.friend_id == ^b) or (f.user_id == ^b and f.friend_id == ^a))
    )
  end

  @doc "Ask `handle` to be friends: `{:ok, :requested | :accepted}` or `{:error, reason}`."
  def request(%User{} = me, handle) do
    with %User{} = them <- Accounts.get_by_handle(handle) || {:error, :no_such_user},
         :ok <- if(them.id == me.id, do: {:error, :yourself}, else: :ok),
         :ok <- under_limit(me) do
      case pair(me.id, them.id) do
        nil ->
          Repo.insert!(%Friendship{user_id: me.id, friend_id: them.id, status: "pending"})
          notify([me.id, them.id])
          {:ok, :requested}

        %Friendship{status: "accepted"} ->
          {:ok, :accepted}

        %Friendship{user_id: id} = f when id == them.id ->
          accept_row(f)
          {:ok, :accepted}

        %Friendship{} ->
          {:ok, :requested}
      end
    end
  end

  @doc "Accept `handle`'s request."
  def accept(%User{} = me, handle) do
    with %User{} = them <- Accounts.get_by_handle(handle) || {:error, :no_such_user} do
      case pair(me.id, them.id) do
        %Friendship{status: "pending", user_id: id} = f when id == them.id ->
          accept_row(f)
          :ok

        %Friendship{status: "accepted"} ->
          :ok

        _ ->
          {:error, :no_request}
      end
    end
  end

  @doc "Unfriend, decline or withdraw: whatever there is between the two goes."
  def remove(%User{} = me, handle) do
    with %User{} = them <- Accounts.get_by_handle(handle) || {:error, :no_such_user} do
      case pair(me.id, them.id) do
        nil -> :ok
        f -> Repo.delete!(f)
      end

      notify([me.id, them.id])
      :ok
    end
  end

  defp accept_row(f) do
    f |> Ecto.Changeset.change(status: "accepted") |> Repo.update!()
    notify([f.user_id, f.friend_id])
  end

  defp pair(a, b) do
    Repo.one(
      from f in Friendship,
        where: (f.user_id == ^a and f.friend_id == ^b) or (f.user_id == ^b and f.friend_id == ^a)
    )
  end

  defp under_limit(me) do
    n = Repo.aggregate(from(f in Friendship, where: f.user_id == ^me.id or f.friend_id == ^me.id), :count)
    if n < @max_friends, do: :ok, else: {:error, :too_many_friends}
  end

  defp notify(ids) do
    for id <- ids, do: SoshWeb.Endpoint.broadcast("user:#{id}", "friends", %{})
  end
end
