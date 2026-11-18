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
      wallet: Players.wallet(u.handle),
      servers: Servers.list(u),
      friends: Friends.list(u),
      conversations: Chat.conversations(u),
      catalog: Character.catalog(),
      universe: universe(u)
    }
  end

  def bag(%User{handle: h}), do: Players.bag_json(Players.bag(h))

  @doc """
  Swap two slots of the bag (sorting it): `{:ok, bag}` as clients want it,
  also told to every client of the account (`user:<id>` `bag`).
  """
  def bag_swap(%User{handle: h, id: id}, a, b) when is_integer(a) and is_integer(b) do
    swapped =
      Players.update_bag(h, fn bag ->
        last = length(bag) - 1

        if a in 0..last//1 and b in 0..last//1,
          do: {:ok, bag |> List.replace_at(a, Enum.at(bag, b)) |> List.replace_at(b, Enum.at(bag, a))},
          else: {:error, :no_such_slot}
      end)

    with {:ok, bag} <- swapped do
      json = Players.bag_json(bag)
      SoshWeb.Endpoint.broadcast("user:#{id}", "bag", %{bag: json})
      {:ok, json}
    end
  end

  def bag_swap(_, _, _), do: {:error, :no_such_slot}

  @doc """
  Sort or set down what's in the bag: `{:move, from, to}` (onto a stack of
  the same thing as far as it goes, two bags of marbles pour together,
  anything else swaps), `{:split, slot, n}` (`n` off into the first empty
  slot; a bag of marbles splits in two) or `{:drop, slot}` (the whole
  stack, at the player's feet in the universe they're in; the action
  channel can aim it). `{:ok, bag}`, also told to every client of the
  account (`user:<id>` `bag`).
  """
  def bag_op(%User{handle: h, id: id}, op) do
    result =
      case op do
        {:move, a, b} -> arranged(h, &Universe.bag_arrange(&1, a, b))
        {:split, s, n} -> arranged(h, &Universe.bag_split(&1, s, n, nil))
        # the universe's calls answer the bag as clients want it already
        {:drop, s} -> drop_here(id, h, s)
        {:drop, s, u, on, pos} -> Sosh.Sim.drop(u, h, on, pos, s)
        {:drop_by, s, u, user} -> Sosh.Sim.drop_here(u, user, h, s)
        _ -> {:error, :bad_request}
      end

    with {:ok, json} <- result do
      SoshWeb.Endpoint.broadcast("user:#{id}", "bag", %{bag: json})
      {:ok, json}
    end
  end

  defp arranged(h, fun) do
    with {:ok, bag} <- Players.change_bag(h, fun), do: {:ok, Players.bag_json(bag)}
  end

  # Wherever one of the account's connections stands in a universe.
  defp drop_here(account_id, h, slot) do
    case Enum.find(Sosh.Lobby.list(), &(&1[:account_id] == account_id)) do
      %{universe: u, user_id: user} ->
        with {:ok, _} <- Sosh.Sim.ensure(u), do: Sosh.Sim.drop_here(u, user, h, slot)

      nil ->
        {:error, :not_in_world}
    end
  end

  @max_slot 255

  @doc "What a bag call's params (`move` [from, to], `split` [slot, n], `drop` slot) ask for."
  def bag_op_of(%{"move" => [a, b]}) when a in 0..@max_slot and b in 0..@max_slot, do: {:move, a, b}

  def bag_op_of(%{"split" => [s, n]}) when s in 0..@max_slot and is_integer(n) and n > 0 and n < 4_294_967_296,
    do: {:split, s, n}

  def bag_op_of(%{"drop" => s}) when s in 0..@max_slot, do: {:drop, s}
  def bag_op_of(_), do: :bad_request

  @doc """
  Marbles between the bag and the wallet: `{:deposit, slot}` empties the
  bag of marbles in that slot into the wallet, `{:withdraw, n}` takes `n`
  out into the bag. `{:ok, %{bag, wallet}}`, also told to every client of
  the account (`user:<id>` `bag` and `wallet`).
  """
  def wallet(%User{handle: h, id: id}, op) do
    result =
      case op do
        {:deposit, slot} -> Players.deposit(h, slot)
        {:withdraw, n} -> Players.withdraw(h, n)
        _ -> {:error, :bad_request}
      end

    with {:ok, bag, wallet} <- result do
      json = Players.bag_json(bag)
      SoshWeb.Endpoint.broadcast("user:#{id}", "bag", %{bag: json})
      SoshWeb.Endpoint.broadcast("user:#{id}", "wallet", %{wallet: wallet})
      {:ok, %{bag: json, wallet: wallet}}
    end
  end

  @doc """
  Do recipe step `step` outside any world: a hand step (no station), or
  one at a station they're recorded as in reach of (`Sosh.Players.stations/1`),
  with no stroke drawn (the least a stroke yields). Furniture too big for a
  bag can't be made this way (`place_or_carry`: it's finished in a world).
  `{:ok, %{step, item, n, score, how, furniture, bag}}`, the bag also told
  to every client of the account (`user:<id>` `bag`).
  """
  def craft(%User{handle: h, id: id}, step) when is_binary(step) and byte_size(step) <= 64 do
    stations = Players.stations(h)

    with {:ok, made, bag} <- Players.change_bag(h, &Universe.craft(step, [], stations, &1)) do
      json = Players.bag_json(bag)
      SoshWeb.Endpoint.broadcast("user:#{id}", "bag", %{bag: json})
      {:ok, Map.put(made, :bag, json)}
    end
  end

  def craft(_, _), do: {:error, :no_such_step}

  @doc "What the wallet's params (`deposit` a slot or `withdraw` a count) ask for."
  def wallet_op(%{"deposit" => slot}) when is_integer(slot), do: {:deposit, slot}
  def wallet_op(%{"withdraw" => n}) when is_integer(n), do: {:withdraw, n}
  def wallet_op(_), do: :bad_request

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
