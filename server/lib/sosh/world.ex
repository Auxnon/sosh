defmodule Sosh.World do
  @moduledoc """
  The block world, as 16x16x16 chunks of one-byte block ids.

  Chunks are loaded lazily: from Postgres (`Sosh.Chunk`) if saved, otherwise
  generated (the starting plaza). Edits mark a chunk dirty; dirty chunks are
  written back every `autosave_ms` (config `:sosh, Sosh.World`), on `save/0`,
  and when the server shuts down.

  Coordinates are Z-up like the client: x,y the ground plane, z height. A
  block at z occupies [z, z+1], so the plaza floor's top is z = 0.
  """
  use GenServer
  require Logger

  alias Sosh.{Chunk, Repo}

  @size 16
  @volume @size * @size * @size

  @blocks %{
    "air" => 0,
    "grass" => 1,
    "dirt" => 2,
    "stone" => 3,
    "wood" => 4,
    "path" => 5,
    "water" => 6,
    "pot" => 7
  }
  @placeable ~w(grass dirt stone wood path pot)

  # The plaza generated where nothing has been saved; mirrors the client's
  # original world.lua layout.
  @plaza_r 18
  @pond {7, -6, 3.2}
  @floor_depth 4

  def size, do: @size
  def block_ids, do: @blocks
  def block_name(id), do: Enum.find_value(@blocks, fn {name, i} -> if i == id, do: name end)
  def placeable, do: @placeable

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Chunk `{cx, cy, cz}` as a #{@volume}-byte binary."
  def chunk(key), do: GenServer.call(__MODULE__, {:chunk, key})

  def block(x, y, z), do: GenServer.call(__MODULE__, {:block, x, y, z})

  @doc "Set a block; returns `{:ok, previous_id}`."
  def put_block(x, y, z, id) when id in 0..255,
    do: GenServer.call(__MODULE__, {:put, x, y, z, id})

  @doc "Write every dirty chunk now. Returns `{:ok, count}`."
  def save, do: GenServer.call(__MODULE__, :save, 30_000)

  @doc "Drop in-memory chunks (unsaved edits are lost). For tests."
  def reset, do: GenServer.call(__MODULE__, :reset)

  def chunk_key(x, y, z), do: {div_floor(x), div_floor(y), div_floor(z)}

  # -- server

  @impl true
  def init(_opts) do
    # So terminate/2 runs (and saves) on a normal shutdown.
    Process.flag(:trap_exit, true)
    schedule_autosave()
    {:ok, %{chunks: %{}, dirty: MapSet.new()}}
  end

  @impl true
  def handle_call({:chunk, key}, _from, state) do
    {bin, state} = fetch(state, key)
    {:reply, bin, state}
  end

  def handle_call({:block, x, y, z}, _from, state) do
    {bin, state} = fetch(state, chunk_key(x, y, z))
    {:reply, :binary.at(bin, index(x, y, z)), state}
  end

  def handle_call({:put, x, y, z, id}, _from, state) do
    key = chunk_key(x, y, z)
    {bin, state} = fetch(state, key)
    i = index(x, y, z)
    old = :binary.at(bin, i)
    bin = binary_part(bin, 0, i) <> <<id>> <> binary_part(bin, i + 1, @volume - i - 1)

    state = %{
      state
      | chunks: Map.put(state.chunks, key, bin),
        dirty: MapSet.put(state.dirty, key)
    }

    {:reply, {:ok, old}, state}
  end

  def handle_call(:save, _from, state) do
    {count, state} = persist(state)
    {:reply, {:ok, count}, state}
  end

  def handle_call(:reset, _from, _state),
    do: {:reply, :ok, %{chunks: %{}, dirty: MapSet.new()}}

  @impl true
  def handle_info(:autosave, state) do
    {count, state} = persist(state)
    if count > 0, do: Logger.info("world: autosaved #{count} chunk(s)")
    schedule_autosave()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    {count, _} = persist(state)
    if count > 0, do: Logger.info("world: saved #{count} chunk(s) on shutdown")
    :ok
  end

  # -- internals

  defp schedule_autosave do
    case Application.get_env(:sosh, __MODULE__, [])[:autosave_ms] do
      ms when is_integer(ms) and ms > 0 -> Process.send_after(self(), :autosave, ms)
      _ -> :ok
    end
  end

  defp fetch(state, key) do
    case state.chunks do
      %{^key => bin} ->
        {bin, state}

      _ ->
        bin = load(key) || generate(key)
        {bin, %{state | chunks: Map.put(state.chunks, key, bin)}}
    end
  end

  defp load({x, y, z}) do
    case Repo.get_by(Chunk, x: x, y: y, z: z) do
      %Chunk{blocks: bin} when byte_size(bin) == @volume -> bin
      _ -> nil
    end
  end

  defp persist(%{dirty: dirty} = state) do
    if MapSet.size(dirty) == 0 do
      {0, state}
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      rows =
        for {x, y, z} = key <- dirty do
          %{x: x, y: y, z: z, blocks: state.chunks[key], inserted_at: now, updated_at: now}
        end

      {count, _} =
        Repo.insert_all(Chunk, rows,
          on_conflict: {:replace, [:blocks, :updated_at]},
          conflict_target: [:x, :y, :z]
        )

      {count, %{state | dirty: MapSet.new()}}
    end
  end

  defp generate({cx, cy, cz}) do
    for lz <- 0..(@size - 1), ly <- 0..(@size - 1), lx <- 0..(@size - 1), into: <<>> do
      <<plaza_block(cx * @size + lx, cy * @size + ly, cz * @size + lz)>>
    end
  end

  defp plaza_block(x, y, z) do
    d = :math.sqrt(x * x + y * y)
    {px, py, pr} = @pond
    pond = :math.sqrt((x - px) * (x - px) + (y - py) * (y - py)) < pr

    cond do
      z >= 0 or z < -@floor_depth or d > @plaza_r -> @blocks["air"]
      z < -2 -> @blocks["stone"]
      z == -2 -> @blocks["dirt"]
      pond -> @blocks["water"]
      d > @plaza_r - 1.5 -> @blocks["stone"]
      x == 0 or y == 0 or (d > 4.5 and d < 6) -> @blocks["path"]
      true -> @blocks["grass"]
    end
  end

  # x fastest, then y, then z
  defp index(x, y, z), do: mod(x) + mod(y) * @size + mod(z) * @size * @size

  defp div_floor(n), do: Integer.floor_div(n, @size)
  defp mod(n), do: Integer.mod(n, @size)

  @doc "Run-length encode a chunk as a flat `[id, count, id, count, ...]` list."
  def rle(bin) do
    bin
    |> :binary.bin_to_list()
    |> Enum.chunk_by(& &1)
    |> Enum.flat_map(fn [id | _] = run -> [id, length(run)] end)
  end
end
