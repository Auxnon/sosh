defmodule Sosh.Players do
  @moduledoc """
  Players by name: what's in their bag and which universe they're in.

  There are no accounts: a player is whoever joins with that name, and a
  new name starts with a bag of building materials (`Sosh.Universe.starter_bag/0`).
  Bags follow players from universe to universe; the universe they're in
  changes them (`Sosh.Sim`) and every change is saved straight away
  (`Sosh.Player`).

  A bag is a list of `nil | {item, count}`.

  Marbles are the money. In a bag they're bags of them (`marbles:<n>`, up
  to 99,999 a bag, set down in the world like furniture); put in the
  wallet they're just a number, up to `wallet_max/0`.
  """
  use GenServer

  alias Sosh.{Player, Repo, Universe}

  @wallet_max 999_999_999

  def wallet_max, do: @wallet_max

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "`%{name, universe, at, bag, wallet}`; a new player starts in universe (0, 0)."
  def get(name), do: GenServer.call(__MODULE__, {:get, name})

  def bag(name), do: get(name).bag

  def put_bag(name, bag), do: GenServer.call(__MODULE__, {:update, name, %{bag: bag}})

  @doc """
  Change a bag in one step, so nothing else changes it in between: `fun`
  gets the bag and returns `{:ok, bag}` to keep or anything else to leave
  it as it was (and that's returned).
  """
  def update_bag(name, fun), do: GenServer.call(__MODULE__, {:update_bag, name, fun})

  @doc """
  Change a bag in one step with a universe call that answers `{:ok, bag}`
  or `{:ok, x, bag}`: the bag is kept and the answer returned; anything
  else leaves the bag as it was.
  """
  def change_bag(name, fun), do: GenServer.call(__MODULE__, {:change_bag, name, fun})

  def wallet(name), do: get(name).wallet

  @doc """
  Empty the bag of marbles in `slot` into the wallet: `{:ok, bag, wallet}`.
  What doesn't fit a full wallet stays in the bag.
  """
  def deposit(name, slot), do: GenServer.call(__MODULE__, {:deposit, name, slot})

  @doc "Take `n` marbles out of the wallet into the bag: `{:ok, bag, wallet}`."
  def withdraw(name, n), do: GenServer.call(__MODULE__, {:withdraw, name, n})

  @doc "They're in universe `u` now, standing at `at` (nil: anywhere)."
  def move(name, u, at \\ nil),
    do: GenServer.call(__MODULE__, {:update, name, %{universe: u, at: at}})

  @doc "They left universe `u` standing at `at`: they come back there."
  def left(name, u, at), do: GenServer.call(__MODULE__, {:left, name, u, at})

  @doc "Forget everything cached (the database stays). For tests."
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc """
  A bag as clients want it: `[[item, count] | []]`. Empty slots are empty
  lists, not null, which a Lua client would read as holes in the array.
  """
  def bag_json(bag) do
    Enum.map(bag, fn
      {i, n} -> [i, n]
      nil -> []
    end)
  end

  # -- server

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:get, name}, _from, state) do
    {p, state} = fetch(state, name)
    {:reply, p, state}
  end

  def handle_call({:update, name, changes}, _from, state) do
    {p, state} = fetch(state, name)
    p = Map.merge(p, changes)
    store(p)
    {:reply, :ok, Map.put(state, name, p)}
  end

  def handle_call({:update_bag, name, fun}, _from, state) do
    {p, state} = fetch(state, name)

    case fun.(p.bag) do
      {:ok, bag} ->
        p = %{p | bag: bag}
        store(p)
        {:reply, {:ok, bag}, Map.put(state, name, p)}

      other ->
        {:reply, other, state}
    end
  end

  def handle_call({:change_bag, name, fun}, _from, state) do
    {p, state} = fetch(state, name)

    case fun.(p.bag) do
      {:ok, bag} = r when is_list(bag) -> {:reply, r, keep(state, %{p | bag: bag})}
      {:ok, _, bag} = r when is_list(bag) -> {:reply, r, keep(state, %{p | bag: bag})}
      other -> {:reply, other, state}
    end
  end

  def handle_call({:deposit, name, slot}, _from, state) do
    {p, state} = fetch(state, name)
    room = @wallet_max - p.wallet

    with true <- is_integer(slot) and slot >= 0 || {:error, :no_such_slot},
         {"marbles:" <> n, 1} <- Enum.at(p.bag, slot) || {:error, :not_marbles},
         {n, ""} <- Integer.parse(n),
         true <- room > 0 || {:error, :wallet_full} do
      k = min(n, room)
      left = if n > k, do: {"marbles:#{n - k}", 1}
      p = %{p | bag: List.replace_at(p.bag, slot, left), wallet: p.wallet + k}
      {:reply, {:ok, p.bag, p.wallet}, keep(state, p)}
    else
      {:error, _} = e -> {:reply, e, state}
      _ -> {:reply, {:error, :not_marbles}, state}
    end
  end

  def handle_call({:withdraw, name, n}, _from, state) do
    {p, state} = fetch(state, name)

    with true <- is_integer(n) and n > 0 || {:error, :invalid_amount},
         true <- n <= p.wallet || {:error, :not_enough},
         {:ok, bag} <- Universe.bag_add_marbles(p.bag, n) do
      p = %{p | bag: bag, wallet: p.wallet - n}
      {:reply, {:ok, p.bag, p.wallet}, keep(state, p)}
    else
      {:error, _} = e -> {:reply, e, state}
    end
  end

  def handle_call({:left, name, u, at}, _from, state) do
    {p, state} = fetch(state, name)

    if p.universe == u do
      p = %{p | at: at}
      store(p)
      {:reply, :ok, Map.put(state, name, p)}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{}}

  defp keep(state, p) do
    store(p)
    Map.put(state, p.name, p)
  end

  defp fetch(state, name) do
    case state do
      %{^name => p} ->
        {p, state}

      _ ->
        p =
          case Repo.get(Player, name) do
            nil -> new(name)
            row -> from_row(row)
          end

        {p, Map.put(state, name, p)}
    end
  end

  defp new(name) do
    p = %{name: name, universe: {0, 0}, at: nil, bag: Universe.starter_bag(), wallet: 0}
    store(p)
    p
  end

  defp from_row(%Player{} = r) do
    slots = Map.get(r.bag, "slots") || []

    bag =
      Enum.map(slots, fn
        [i, n] -> {i, n}
        _ -> nil
      end)

    at = if r.at, do: List.to_tuple(r.at)
    %{name: r.name, universe: {r.gx, r.gy}, at: at, bag: bag, wallet: r.wallet || 0}
  end

  defp store(%{name: name, universe: {gx, gy}, at: at, bag: bag, wallet: wallet}) do
    at = if at, do: Enum.map(Tuple.to_list(at), &(&1 * 1.0))

    Repo.insert!(
      %Player{name: name, gx: gx, gy: gy, at: at, bag: %{"slots" => bag_json(bag)}, wallet: wallet},
      on_conflict: {:replace, [:gx, :gy, :at, :bag, :wallet, :updated_at]},
      conflict_target: :name
    )
  end
end
