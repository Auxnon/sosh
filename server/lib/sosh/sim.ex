defmodule Sosh.Sim do
  @moduledoc """
  Runs the living part of the world in a `Sosh.Universe` (Rust): carrots that
  grow on wall-clock time, cows that wander the plaza and get pushed by
  players, and what players carry. The universe decides what can be carried
  (`Universe.carryable/0`, any cow) and who holds what.

  Every `tick_ms` it advances the universe with the players' positions as
  `Sosh.Lobby` predicts them and broadcasts what changed on `actions:lobby`:

    * `cows` `%{cows: [[id, x, y, z, heading]]}` - cows that moved
    * `moo` `%{ids: [id]}` - cows that were just shoved
    * `crop` `%{position: [x, y, z], stage: 0..3}` - a crop grew (3 is ripe)
    * `carry` `%{user_id, block, cow}` - what someone now holds: a block id,
      a cow id, or neither (both nil); a carried cow rides over their head
    * `block_changed` - as `SoshWeb.ActionChannel`'s, when carrying takes a
      block out of the world or puts one back

  Crops persist in Postgres (`Sosh.Crop`) as the time they were planted, so
  they keep growing while the server is down. Cows don't persist; `cows`
  spawn on every start, and what's carried is lost with them.

  The universe walks on a mirror of the plaza's chunks from `Sosh.World`,
  loaded at start and kept current by `block_changed/2`.
  """
  use GenServer
  require Logger

  import Ecto.Query, only: [from: 2]

  alias Sosh.{Crop, Lobby, Repo, Universe, World}

  @topic "actions:lobby"
  @ripe 3
  # chunks the cows walk on: x, y in -32..31 covers the plaza; the floor
  # layer and the one above it
  @area for cx <- -2..1, cy <- -2..1, cz <- -1..0, do: {cx, cy, cz}
  @cow_spots [{-6, 5}, {-8, -4}, {4, 9}, {10, 3}, {-3, -10}, {-11, 8}, {2, -12}, {12, -1}]

  def ripe, do: @ripe

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Everything a newcomer needs: `%{cows: [...], crops: [...], held: [carry],
  carryable: [block_id]}`.
  """
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "The crop's stage at `{x, y, z}`, or nil."
  def crop(pos), do: GenServer.call(__MODULE__, {:crop, pos})

  @doc "Plant a carrot in the air cell `{x, y, z}`; the soil is the caller's job."
  def plant(pos), do: GenServer.call(__MODULE__, {:plant, pos})

  @doc "Pick a ripe crop: `{:ok, stage}`, or an error if unripe or absent."
  def harvest(pos), do: GenServer.call(__MODULE__, {:remove, pos, :ripe})

  @doc "Remove a crop whatever its stage (its soil was dug away)."
  def uproot(pos), do: GenServer.call(__MODULE__, {:remove, pos, :any})

  @doc """
  `user` standing at `at` (`{x, y, z}` feet) picks up `{:block, {x, y, z}}`
  or `{:cow, id}`. A block leaves the world. `{:ok, %{block: id}}`,
  `{:ok, %{cow: id}}` or `{:error, reason}`.
  """
  def pick_up(user, what, at), do: GenServer.call(__MODULE__, {:pick_up, user, what, at})

  @doc "`user` puts what they carry in cell `{x, y, z}`; replies as `pick_up/3`."
  def put_down(user, pos), do: GenServer.call(__MODULE__, {:put_down, user, pos})

  @doc "`user` left: set down whatever they carried where they last stood."
  def release(user), do: GenServer.call(__MODULE__, {:release, user})

  @doc "Keep the walking mirror current after a `Sosh.World` edit."
  def block_changed(pos, id), do: GenServer.cast(__MODULE__, {:block, pos, id})

  @doc "Advance to `now_ms` and broadcast, as a timer tick does. For tests."
  def tick(now_ms), do: GenServer.call(__MODULE__, {:tick, now_ms})

  @doc "Start over: reload terrain and crops, respawn cows. For tests."
  def reset(opts \\ []), do: GenServer.call(__MODULE__, {:reset, opts})

  # -- server

  @impl true
  def init(_opts) do
    config = Application.get_env(:sosh, __MODULE__, [])

    state = %{
      universe: nil,
      tick_ms: config[:tick_ms],
      stage_ms: config[:stage_ms] || 60_000,
      cows: config[:cows] || 0
    }

    if config[:autoload] == false do
      {:ok, %{state | universe: Universe.bigbang(state.stage_ms, seed())}}
    else
      {:ok, state, {:continue, :load}}
    end
  end

  @impl true
  def handle_continue(:load, state) do
    state = build(state)
    schedule(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    crops = for {pos, stage} <- Universe.crops(state.universe), do: crop_json(pos, stage)
    cows = Enum.map(Universe.cows(state.universe), &cow_json/1)
    held = for {user, held} <- Universe.holding(state.universe), do: carry_json(user, held)

    {:reply, %{cows: cows, crops: crops, held: held, carryable: Universe.carryable()}, state}
  end

  def handle_call({:pick_up, user, {:block, {x, y, z} = pos}, at}, _from, state) do
    reply =
      with {:ok, held} <-
             Universe.pick_block(state.universe, user, floats(at), World.block(x, y, z)) do
        set_block(state, user, pos, 0)
        carried(user, held)
      end

    {:reply, reply, state}
  end

  def handle_call({:pick_up, user, {:cow, id}, at}, _from, state) do
    reply =
      with {:ok, held} <- Universe.pick_cow(state.universe, user, floats(at), id),
           do: carried(user, held)

    {:reply, reply, state}
  end

  def handle_call({:put_down, user, {x, y, z} = pos}, _from, state) do
    # room for a block: air or water, nothing growing
    free = World.block(x, y, z) in [0, 6] and Universe.crop(state.universe, pos) == nil

    reply =
      case Universe.put_down(state.universe, user, pos, free) do
        {:ok, {:block, id} = held} ->
          set_block(state, user, pos, id)
          carried(user, nil)
          {:ok, held_json(held)}

        {:ok, held} ->
          carried(user, nil)
          {:ok, held_json(held)}

        error ->
          error
      end

    {:reply, reply, state}
  end

  def handle_call({:release, user}, _from, state) do
    case Universe.release(state.universe, user) do
      nil ->
        :ok

      {{:block, id}, {x, y, z}} ->
        # back where they stood, or the first free cell above; else it's lost
        spot =
          Enum.find(z..(z + 3), fn z ->
            World.block(x, y, z) == 0 and Universe.crop(state.universe, {x, y, z}) == nil
          end)

        if spot, do: set_block(state, user, {x, y, spot}, id)
        carried(user, nil)

      {{:cow, _}, _} ->
        carried(user, nil)
    end

    {:reply, :ok, state}
  end

  def handle_call({:crop, pos}, _from, state),
    do: {:reply, Universe.crop(state.universe, pos), state}

  def handle_call({:plant, {x, y, z} = pos}, _from, state) do
    now = now_ms()

    if Universe.plant(state.universe, pos, now, now) do
      Repo.insert!(%Crop{x: x, y: y, z: z, planted_ms: now},
        on_conflict: :replace_all,
        conflict_target: [:x, :y, :z]
      )

      broadcast("crop", crop_json(pos, 0))
      {:reply, :ok, state}
    else
      {:reply, {:error, "occupied"}, state}
    end
  end

  def handle_call({:remove, {x, y, z} = pos, need}, _from, state) do
    case Universe.crop(state.universe, pos) do
      nil ->
        {:reply, {:error, "nothing_growing"}, state}

      stage when need == :ripe and stage < @ripe ->
        {:reply, {:error, "not_ripe"}, state}

      stage ->
        Universe.remove_crop(state.universe, pos)
        Repo.delete_all(from(c in Crop, where: c.x == ^x and c.y == ^y and c.z == ^z))
        broadcast("crop", crop_json(pos, nil))
        {:reply, {:ok, stage}, state}
    end
  end

  def handle_call({:tick, now}, _from, state) do
    step(state, now)
    {:reply, :ok, state}
  end

  def handle_call({:reset, opts}, _from, state) do
    state = build(%{state | cows: Keyword.get(opts, :cows, state.cows)})
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:block, pos, id}, state) do
    Universe.set_block(state.universe, pos, id)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule(state)
    step(state, now_ms())
    {:noreply, state}
  end

  # -- internals

  defp build(state) do
    u = Universe.bigbang(state.stage_ms, seed())
    Enum.each(@area, &Universe.load_chunk(u, &1, World.chunk(&1)))

    now = now_ms()

    for %Crop{x: x, y: y, z: z, planted_ms: t} <- Repo.all(Crop),
        do: Universe.plant(u, {x, y, z}, t, now)

    @cow_spots
    |> Enum.take(state.cows)
    |> Enum.each(fn {x, y} -> Universe.spawn_cow(u, x * 1.0, y * 1.0) end)

    %{state | universe: u}
  end

  defp step(state, now) do
    t = Lobby.now()

    players =
      for p <- Lobby.list(),
          [x, y, z] = Lobby.position(p, t),
          do: {p.user_id, x * 1.0, y * 1.0, z * 1.0}

    {cows, moos, crops} = Universe.tick(state.universe, now, players)

    if cows != [], do: broadcast("cows", %{cows: Enum.map(cows, &cow_json/1)})
    if moos != [], do: broadcast("moo", %{ids: moos})
    Enum.each(crops, fn {pos, stage} -> broadcast("crop", crop_json(pos, stage)) end)
  end

  defp schedule(%{tick_ms: ms}) when is_integer(ms) and ms > 0,
    do: Process.send_after(self(), :tick, ms)

  defp schedule(_), do: :ok

  # The world's block at `pos` becomes `id`, by `user`'s carrying.
  defp set_block(state, user, {x, y, z} = pos, id) do
    {:ok, _} = World.put_block(x, y, z, id)
    Universe.set_block(state.universe, pos, id)

    broadcast("block_changed", %{
      user_id: user,
      position: [x, y, z],
      block: id,
      block_type: World.block_name(id)
    })
  end

  # Tell everyone what `user` holds now (nil: nothing); replies as pick_up/3.
  defp carried(user, held) do
    broadcast("carry", carry_json(user, held))
    {:ok, held_json(held)}
  end

  defp carry_json(user, held), do: Map.put(held_json(held), :user_id, user)

  defp held_json({:block, id}), do: %{block: id, cow: nil}
  defp held_json({:cow, id}), do: %{block: nil, cow: id}
  defp held_json(nil), do: %{block: nil, cow: nil}

  defp floats({x, y, z}), do: {x * 1.0, y * 1.0, z * 1.0}

  defp broadcast(event, payload), do: SoshWeb.Endpoint.broadcast(@topic, event, payload)

  # stage nil: the crop is gone
  defp crop_json({x, y, z}, stage), do: %{position: [x, y, z], stage: stage}

  defp cow_json({id, x, y, z, h}),
    do: [id, Float.round(x, 3), Float.round(y, 3), Float.round(z, 3), Float.round(h, 3)]

  defp now_ms, do: System.os_time(:millisecond)

  defp seed, do: :rand.uniform(4_611_686_018_427_387_903)
end
