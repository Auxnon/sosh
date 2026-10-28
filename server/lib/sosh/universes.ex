defmodule Sosh.Universes do
  @moduledoc """
  The grid of universes. Each is a cell `{gx, gy}` of the grid (+x east,
  +y north) with its own Rust universe run by a `Sosh.Sim`. Flying off one
  side of a universe crosses into its neighbour on that side, if the grid
  has one there; if not, that side is closed.

  Which universes exist lives in Postgres (`Sosh.UniverseRecord`). A fresh
  database gets universe (0, 0), the plaza over the sea, and (1, 0) east of
  it, islands over wild land. `create/3` adds more.
  """
  require Logger

  alias Sosh.{Repo, Sim, UniverseRecord}

  @sides [east: {1, 0}, west: {-1, 0}, north: {0, 1}, south: {0, -1}]
  @kinds ~w(sea land)
  @defaults [{{0, 0}, "sea"}, {{1, 0}, "land"}]

  def kinds, do: @kinds

  def get({gx, gy}), do: Repo.get_by(UniverseRecord, gx: gx, gy: gy)

  def exists?(u), do: get(u) != nil

  def list, do: Enum.map(Repo.all(UniverseRecord), &{&1.gx, &1.gy})

  @doc """
  Add universe `u` to the grid (a no-op if it's there). Neighbours that are
  running open the side facing it.
  """
  def create({gx, gy} = u, kind \\ "sea", seed \\ nil) when kind in @kinds do
    seed = seed || :rand.uniform(4_611_686_018_427_387_903)

    Repo.insert!(%UniverseRecord{gx: gx, gy: gy, kind: kind, seed: seed},
      on_conflict: :nothing,
      conflict_target: [:gx, :gy]
    )

    for {_, n} <- neighbours(u), do: Sim.reopen(n)
    get(u)
  end

  @doc "The universe on `side` (:east, :west, :north or :south) of `u`."
  def beside({gx, gy}, side) do
    {dx, dy} = Keyword.fetch!(@sides, side)
    {gx + dx, gy + dy}
  end

  def neighbours(u), do: for({side, _} <- @sides, do: {side, beside(u, side)})

  @doc "Which sides of `u` have a neighbour: `[east, west, north, south]`."
  def open(u), do: for({_, n} <- neighbours(u), do: exists?(n))

  def opposite(:east), do: :west
  def opposite(:west), do: :east
  def opposite(:north), do: :south
  def opposite(:south), do: :north

  def side(name) when is_binary(name),
    do: Enum.find(Keyword.keys(@sides), &(to_string(&1) == name))

  @doc ~S|The `"gx,gy"` in a universe's channel topics.|
  def key({gx, gy}), do: "#{gx},#{gy}"

  def parse(key) when is_binary(key) do
    with [a, b] <- String.split(key, ","),
         {gx, ""} <- Integer.parse(a),
         {gy, ""} <- Integer.parse(b) do
      {:ok, {gx, gy}}
    else
      _ -> :error
    end
  end

  @doc """
  Make sure the grid has its first universes and start every universe, so
  idle ones run their ambient systems.
  """
  def boot do
    if Application.get_env(:sosh, __MODULE__, [])[:boot] != false do
      if list() == [], do: Enum.each(@defaults, fn {u, kind} -> create(u, kind) end)
      # the ten seeded servers, each a universe
      Sosh.Servers.seed()
      us = list()
      Enum.each(us, &Sim.ensure/1)
      Logger.info("universes: #{length(us)} running")
    end

    :ok
  end
end
