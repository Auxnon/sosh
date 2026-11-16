defmodule Sosh.Maps do
  @moduledoc """
  Universes' maps: a rough isometric picture of each one's blocks, islands,
  builds and airships (drawn by the NIF, `map.rs`), as a PNG. They're
  redrawn when a universe saves (`Sosh.Sim`), kept on its row
  (`universes.map`), and served at `/map/<gx>,<gy>`; a server's `map` is
  that path, its banner.
  """
  import Ecto.Query

  alias Sosh.{Repo, Sim, Universe, UniverseRecord}

  @doc "The path a universe's map is served at."
  def path({gx, gy}), do: "/map/#{gx},#{gy}"

  @doc "Draw universe `uni` (a running Sim's) and keep it as `u`'s map."
  def draw(uni, {gx, gy}) do
    {w, h, rgb} = Universe.map(uni)
    png = png(w, h, rgb)
    at = DateTime.utc_now() |> DateTime.truncate(:second)
    from(r in UniverseRecord, where: r.gx == ^gx and r.gy == ^gy) |> Repo.update_all(set: [map: png, map_at: at])
    {png, at}
  end

  @doc """
  `u`'s map as `{png, drawn_at}`: the kept one, or drawn now (starting the
  universe) if it has none yet. nil if there's no such universe.
  """
  def get({gx, gy} = u) do
    case Repo.one(from r in UniverseRecord, where: r.gx == ^gx and r.gy == ^gy, select: {r.map, r.map_at}) do
      nil ->
        nil

      {nil, _} ->
        with {:ok, _} <- Sim.ensure(u), {:ok, kept} <- Sim.map(u), do: kept, else: (_ -> nil)

      kept ->
        kept
    end
  end

  @doc "RGB rows (top first) as a PNG."
  def png(w, h, rgb) when byte_size(rgb) == w * h * 3 do
    stride = w * 3
    # each row with filter 0 (none) before it
    raw = for i <- 0..(h - 1), into: <<>>, do: <<0, binary_part(rgb, i * stride, stride)::binary>>

    <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <>
      chunk("IHDR", <<w::32, h::32, 8, 2, 0, 0, 0>>) <>
      chunk("IDAT", :zlib.compress(raw)) <>
      chunk("IEND", "")
  end

  defp chunk(type, data),
    do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
end
