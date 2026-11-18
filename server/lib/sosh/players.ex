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

  @crafting_max 20
  @recipe_max 64
  @station_max 32
  @stations_max 32

  def wallet_max, do: @wallet_max

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "`%{name, universe, at, bag, wallet, crafting, stations}`; a new player starts in universe (0, 0)."
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
  The recipes they have in progress: `%{recipe => %{"step" => n, "at" => unix seconds}}`.
  """
  def crafting(name), do: get(name).crafting

  @doc """
  Save the recipes in progress, cleaned (`clean_crafting/1`): `{:ok, saved}`.
  A change is pushed to the account's clients as `crafting` on `user:<id>`.
  """
  def set_crafting(name, map),
    do: GenServer.call(__MODULE__, {:set_crafting, name, clean_crafting(map)})

  @doc "The station kinds they're in range of right now, sorted."
  def stations(name), do: get(name).stations

  @doc """
  Record which station kinds they're in range of (only a universe's sim
  calls this): `{:ok, saved}`, sorted and de-duplicated. A change is pushed
  as `stations` on `user:<id>`. They're emptied when the player leaves.
  """
  def set_stations(name, list),
    do: GenServer.call(__MODULE__, {:set_stations, name, clean_stations(list)})

  @doc """
  Clean a crafting map: keys are recipe names (strings, up to
  #{@recipe_max} bytes), values keep an integer `step` >= 0 and an integer
  `at`; anything else is dropped. Only the #{@crafting_max} most recent
  (by `at`) are kept.
  """
  def clean_crafting(map) when is_map(map) do
    map
    |> Enum.flat_map(fn
      {k, %{} = v} when is_binary(k) and byte_size(k) in 1..@recipe_max ->
        step = Map.get(v, "step", Map.get(v, :step))
        at = Map.get(v, "at", Map.get(v, :at))

        if is_integer(step) and step >= 0 and is_integer(at),
          do: [{k, %{"step" => step, "at" => at}}],
          else: []

      _ ->
        []
    end)
    |> Enum.sort_by(fn {k, v} -> {-v["at"], k} end)
    |> Enum.take(@crafting_max)
    |> Map.new()
  end

  def clean_crafting(_), do: %{}

  @doc "A station list cleaned: strings of 1 to #{@station_max} bytes, sorted, once each (at most #{@stations_max})."
  def clean_stations(list) when is_list(list) do
    list
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) in 1..@station_max))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@stations_max)
  end

  def clean_stations(_), do: []

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
    was = p.stations
    from = p.universe
    p = Map.merge(p, changes)
    # changing universe leaves the old one's stations behind
    p = if p.universe != from, do: %{p | stations: []}, else: p
    if was != [] and p.stations == [], do: push(name, "stations", %{stations: []})
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

  def handle_call({:set_crafting, name, map}, _from, state) do
    {p, state} = fetch(state, name)

    if p.crafting == map do
      {:reply, {:ok, map}, state}
    else
      push(name, "crafting", %{crafting: map})
      {:reply, {:ok, map}, keep(state, %{p | crafting: map})}
    end
  end

  def handle_call({:set_stations, name, list}, _from, state) do
    {p, state} = fetch(state, name)

    if p.stations == list do
      {:reply, {:ok, list}, state}
    else
      push(name, "stations", %{stations: list})
      {:reply, {:ok, list}, keep(state, %{p | stations: list})}
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
      was = p.stations
      p = %{p | at: at, stations: []}
      store(p)
      if was != [], do: push(name, "stations", %{stations: []})
      {:reply, :ok, Map.put(state, name, p)}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{}}

  # Tell every client of the player's account (the player is named by handle).
  defp push(name, event, payload) do
    case Sosh.Accounts.get_by_handle(name) do
      %{id: id} -> SoshWeb.Endpoint.broadcast("user:#{id}", event, payload)
      nil -> :ok
    end
  end

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
    p = %{name: name, universe: {0, 0}, at: nil, bag: Universe.starter_bag(), wallet: 0, crafting: %{}, stations: []}
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
    %{
      name: r.name,
      universe: {r.gx, r.gy},
      at: at,
      bag: bag,
      wallet: r.wallet || 0,
      crafting: clean_crafting(r.crafting || %{}),
      stations: clean_stations(r.stations || [])
    }
  end

  defp store(%{name: name, universe: {gx, gy}, at: at, bag: bag, wallet: wallet} = p) do
    at = if at, do: Enum.map(Tuple.to_list(at), &(&1 * 1.0))

    Repo.insert!(
      %Player{name: name, gx: gx, gy: gy, at: at, bag: %{"slots" => bag_json(bag)},
        wallet: wallet,
        crafting: p.crafting,
        stations: p.stations
      },
      on_conflict: {:replace, [:gx, :gy, :at, :bag, :wallet, :crafting, :stations, :updated_at]},
      conflict_target: :name
    )
  end
end
