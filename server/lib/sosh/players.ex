defmodule Sosh.Players do
  @moduledoc """
  Players by name: what's in their bag and which universe they're in.

  There are no accounts: a player is whoever joins with that name, and a
  new name starts with a bag of building materials (`Sosh.Universe.starter_bag/0`).
  Bags follow players from universe to universe; the universe they're in
  changes them (`Sosh.Sim`) and every change is saved straight away
  (`Sosh.Player`).

  A bag is a list of `nil | {item, count}`.
  """
  use GenServer

  alias Sosh.{Player, Repo, Universe}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "`%{name, universe, at, bag}`; a new player starts in universe (0, 0)."
  def get(name), do: GenServer.call(__MODULE__, {:get, name})

  def bag(name), do: get(name).bag

  def put_bag(name, bag), do: GenServer.call(__MODULE__, {:update, name, %{bag: bag}})

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
    p = %{name: name, universe: {0, 0}, at: nil, bag: Universe.starter_bag()}
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
    %{name: r.name, universe: {r.gx, r.gy}, at: at, bag: bag}
  end

  defp store(%{name: name, universe: {gx, gy}, at: at, bag: bag}) do
    at = if at, do: Enum.map(Tuple.to_list(at), &(&1 * 1.0))

    Repo.insert!(
      %Player{name: name, gx: gx, gy: gy, at: at, bag: %{"slots" => bag_json(bag)}},
      on_conflict: {:replace, [:gx, :gy, :at, :bag, :updated_at]},
      conflict_target: :name
    )
  end
end
