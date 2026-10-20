defmodule Sosh.World do
  @moduledoc """
  Block ids and names, and the saved chunks of each universe.

  A universe's blocks live in its Rust universe (`Sosh.Sim`), generated
  from its seed as floating islands. Only chunks someone has changed are
  kept, in Postgres (`Sosh.Chunk`), one 4096-byte row per 16x16x16 chunk;
  `Sosh.Sim` loads them on start and writes back the changed ones.

  Coordinates are Z-up like the client: x,y the ground plane, z height. A
  block at z occupies [z, z+1], so the plaza floor's top is z = 0.
  """
  import Ecto.Query, only: [from: 2]

  alias Sosh.{Chunk, Repo}

  @blocks %{
    "air" => 0,
    "grass" => 1,
    "dirt" => 2,
    "stone" => 3,
    "wood" => 4,
    "path" => 5,
    "water" => 6,
    "pot" => 7,
    # taken by furniture, or by a blueprint's scaffolding
    "furniture" => 8,
    "scaffold" => 9,
    # what airships are built of
    "deck" => 10,
    "hull" => 11,
    "balloon" => 12,
    "rail" => 13,
    "helm" => 14
  }

  def block_ids, do: @blocks
  def block_name(id), do: Enum.find_value(@blocks, fn {name, i} -> if i == id, do: name end)

  @doc "Universe `{gx, gy}`'s saved chunks, as `{{cx, cy, cz}, binary}`."
  def load({gx, gy}) do
    Repo.all(
      from(c in Chunk, where: c.gx == ^gx and c.gy == ^gy, select: {{c.x, c.y, c.z}, c.blocks})
    )
  end

  @doc "Save `{key, binary}` chunks of universe `{gx, gy}`. Returns the count."
  def store(_u, []), do: 0

  def store({gx, gy}, chunks) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      for {{x, y, z}, bin} <- chunks do
        %{gx: gx, gy: gy, x: x, y: y, z: z, blocks: bin, inserted_at: now, updated_at: now}
      end

    {count, _} =
      Repo.insert_all(Chunk, rows,
        on_conflict: {:replace, [:blocks, :updated_at]},
        conflict_target: [:gx, :gy, :x, :y, :z]
      )

    count
  end
end
