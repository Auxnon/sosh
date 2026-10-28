defmodule Sosh.Me do
  @moduledoc """
  An account's view of everything, for clients: who they are, their bag,
  their servers, friends and conversations, and the character catalog. The
  API (`SoshWeb.Api`) and the socket (`SoshWeb.UserChannel`) both answer
  with these.
  """
  alias Sosh.{Character, Chat, Friends, Players, Servers, Universe}
  alias Sosh.Accounts.User

  @doc "Someone just signed in (or confirmed): they're on the plaza's server."
  def signed_in(%User{} = user) do
    Servers.join_home(user)
    :ok
  end

  def user(%User{} = u) do
    %{
      id: u.id,
      handle: u.handle,
      email: u.email,
      confirmed: u.confirmed_at != nil,
      character: Character.clean(u.character)
    }
  end

  def session(%User{} = u, token), do: %{token: token, user: user(u)}

  def everything(%User{} = u) do
    %{
      user: user(u),
      bag: bag(u),
      servers: Servers.list(u),
      friends: Friends.list(u),
      conversations: Chat.conversations(u),
      catalog: Character.catalog(),
      universe: universe(u)
    }
  end

  def bag(%User{handle: h}), do: Players.bag_json(Players.bag(h))

  def universe(%User{handle: h}) do
    {gx, gy} = Players.get(h).universe
    [gx, gy]
  end

  @doc """
  Save a character (cleaned). What's in the hand has to be in the bag, or
  the hand goes empty.
  """
  def set_character(%User{} = u, c) do
    c = Character.clean(c)

    c =
      case c["hand"] do
        nil -> c
        item -> if count(u, item) > 0, do: c, else: Map.put(c, "hand", nil)
      end

    with {:ok, u} <- Sosh.Accounts.set_character(u, c) do
      SoshWeb.Endpoint.broadcast("user:#{u.id}", "character", %{character: c})
      restyle(u.handle, c)
      {:ok, u}
    end
  end

  # Everyone in the universe they're standing in sees the change.
  defp restyle(handle, c) do
    for %{name: ^handle, user_id: id, universe: {gx, gy}} <- Sosh.Lobby.list() do
      Sosh.Lobby.update(id, %{character: c})
      SoshWeb.Endpoint.broadcast("room:#{gx},#{gy}", "character", %{user_id: id, character: c})
    end
  end

  defp count(%User{handle: h}, item) do
    Players.bag(h)
    |> Enum.reduce(0, fn
      {^item, n}, acc -> acc + n
      _, acc -> acc
    end)
  end

  @doc false
  def starter_bag, do: Universe.starter_bag()
end
