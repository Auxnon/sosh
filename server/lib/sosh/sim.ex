defmodule Sosh.Sim do
  @moduledoc """
  Runs the living part of the world in a `Sosh.Universe` (Rust): carrots that
  grow on wall-clock time and cows that wander the plaza and get pushed by
  players.

  Every `tick_ms` it advances the universe with the players' positions from
  `Sosh.Lobby` and broadcasts what changed on `actions:lobby`:

    * `cows` `%{cows: [[id, x, y, z, heading]]}` - cows that moved
    * `moo` `%{ids: [id]}` - cows that were just shoved
    * `crop` `%{position: [x, y, z], stage: 0..3}` - a crop grew (3 is ripe)

  Crops persist in Postgres (`Sosh.Crop`) as the time they were planted, so
  they keep growing while the server is down. Cows don't persist; `cows`
  spawn on every start.

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

  @doc "Everything a newcomer needs: `%{cows: [...], crops: [...]}`."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "The crop's stage at `{x, y, z}`, or nil."
  def crop(pos), do: GenServer.call(__MODULE__, {:crop, pos})

  @doc "Plant a carrot in the air cell `{x, y, z}`; the soil is the caller's job."
  def plant(pos), do: GenServer.call(__MODULE__, {:plant, pos})

  @doc "Pick a ripe crop: `{:ok, stage}`, or an error if unripe or absent."
  def harvest(pos), do: GenServer.call(__MODULE__, {:remove, pos, :ripe})

  @doc "Remove a crop whatever its stage (its soil was dug away)."
  def uproot(pos), do: GenServer.call(__MODULE__, {:remove, pos, :any})

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
    {:reply, %{cows: cows, crops: crops}, state}
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
        Repo.delete_all(from c in Crop, where: c.x == ^x and c.y == ^y and c.z == ^z)
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
    players =
      for p <- Lobby.list(),
          [x, y, z] <- [Map.get(p, :at) || p.vec],
          do: {x * 1.0, y * 1.0, z * 1.0}

    {cows, moos, crops} = Universe.tick(state.universe, now, players)

    if cows != [], do: broadcast("cows", %{cows: Enum.map(cows, &cow_json/1)})
    if moos != [], do: broadcast("moo", %{ids: moos})
    Enum.each(crops, fn {pos, stage} -> broadcast("crop", crop_json(pos, stage)) end)
  end

  defp schedule(%{tick_ms: ms}) when is_integer(ms) and ms > 0,
    do: Process.send_after(self(), :tick, ms)

  defp schedule(_), do: :ok

  defp broadcast(event, payload), do: SoshWeb.Endpoint.broadcast(@topic, event, payload)

  # stage nil: the crop is gone
  defp crop_json({x, y, z}, stage), do: %{position: [x, y, z], stage: stage}

  defp cow_json({id, x, y, z, h}),
    do: [id, Float.round(x, 3), Float.round(y, 3), Float.round(z, 3), Float.round(h, 3)]

  defp now_ms, do: System.os_time(:millisecond)

  defp seed, do: :rand.uniform(4_611_686_018_427_387_903)
end
